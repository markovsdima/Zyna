//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK
import KeychainAccess

// MARK: - Client State

enum MatrixClientState {
    case loggedOut
    case loggingIn
    case loggedIn
    case syncing
    case softLoggedOut
    case sessionRecoveryRequired
    case error(Error)
}

enum BackupUploadWaitFailure: Error {
    case timedOut
    case backupDisabled
    case connection
    case lagged
    case unknown
}

extension BackupUploadWaitFailure {
    var isBackupDisabled: Bool {
        if case .backupDisabled = self {
            return true
        }
        return false
    }
}

struct SessionRecoveryCredentials {
    let userId: String
    let deviceId: String?
    let homeserverUrl: String?
    let canSignIn: Bool
}

private let logAuth = ScopedLog(.auth)
private let logSync = ScopedLog(.sync)
private let logRecoveryReset = ScopedLog(.auth, prefix: "[auth] recoveryReset")

private enum SessionRecoverySource {
    case softLogout
    case restoreFailure

    var state: MatrixClientState {
        switch self {
        case .softLogout:
            return .softLoggedOut
        case .restoreFailure:
            return .sessionRecoveryRequired
        }
    }

    var logPrefix: String {
        switch self {
        case .softLogout:
            return "Soft logout"
        case .restoreFailure:
            return "Session restore failed"
        }
    }
}

// MARK: - Matrix Client Service

final class MatrixClientService {

    static let shared = MatrixClientService()

    // MARK: - Published State

    let stateSubject = CurrentValueSubject<MatrixClientState, Never>(.loggedOut)
    var state: MatrixClientState { stateSubject.value }

    /// Live encryption state from SDK listeners. `.unknown` until
    /// the SDK fires the first event after listener attach (which
    /// happens shortly after sync starts). `SessionVerificationService`
    /// reads from these to decide whether to show the verification
    /// screen on launch.
    let verificationStateSubject = CurrentValueSubject<VerificationState, Never>(.unknown)
    let recoveryStateSubject = CurrentValueSubject<RecoveryState, Never>(.unknown)

    // MARK: - SDK Objects

    private(set) var client: Client?
    private(set) var syncService: SyncService?
    private(set) var roomListService: RoomListService?

    // MARK: - Private

    private let sessionDelegate = DefaultSessionDelegate()
    private let passphrase: String
    private var syncStateHandle: TaskHandle?
    private var verificationStateHandle: TaskHandle?
    private var recoveryStateHandle: TaskHandle?
    private var clientDelegateHandle: TaskHandle?
    private var clientDelegate: ZynaClientDelegate?
    private var utdDelegate: ZynaUnableToDecryptDelegate?
    private var sessionRecoverySession: MatrixRustSDK.Session?
    private var sessionRecoverySource: SessionRecoverySource = .softLogout
    private let invalidatingSession = Atomic(false)
    private let sessionRecoveryActive = Atomic(false)

    private let userIdKey = "com.zyna.matrix.lastUserId"
    private let localSessionIdKey = "com.zyna.matrix.localSessionId"
    private static let passphraseKeychainKey = "com.zyna.matrix.storePassphrase"
    // MSC4268 encrypted history sharing is experimental and affects privacy expectations:
    // invited users may receive keys for earlier room history. Keep disabled until the app has explicit UX for that behavior.
    private static let enableEncryptedHistorySharingOnInvite = false
    private static let roomKeyRecipientStrategy: CollectStrategy = .identityBasedStrategy
    private static let decryptionSettings = DecryptionSettings(senderDeviceTrustRequirement: .crossSignedOrLegacy)

    private init() {
        let keychain = Keychain(service: "com.zyna.matrix.crypto")
            .accessibility(.afterFirstUnlockThisDeviceOnly)

        if let stored = try? keychain.get(Self.passphraseKeychainKey) {
            passphrase = stored
        } else {
            let generated = EncryptionKeyProvider().generateKey().base64EncodedString()
            try? keychain.set(generated, key: Self.passphraseKeychainKey)
            passphrase = generated
        }
    }

    // MARK: - Session Paths

    private func sessionDataPath(for userId: String? = nil) -> String {
        let dir = legacyMatrixDataDirectory()
        _ = try? LocalDataProtection.createProtectedDirectory(
            at: dir,
            protection: .backgroundReadable,
            excludeFromBackup: true
        )
        return dir.path
    }

    private func sessionCachePath(for userId: String? = nil) -> String {
        let dir = legacyMatrixCacheDirectory()
        _ = try? LocalDataProtection.createProtectedDirectory(
            at: dir,
            protection: .backgroundReadable,
            excludeFromBackup: true
        )
        return dir.path
    }

    private func legacyMatrixDataDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
    }

    private func legacyMatrixCacheDirectory() -> URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
    }

    private func removeEmptyDirectory(_ url: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else {
            return
        }
        try? fm.removeItem(at: url)
    }

    /// Removes session data/cache directories so a fresh login doesn't collide
    /// with a previous device's crypto store.
    private func clearSessionDirectories(userId: String? = nil) {
        let fm = FileManager.default
        try? fm.removeItem(at: LocalDataProtection.matrixDataDirectory(for: nil))
        try? fm.removeItem(at: LocalDataProtection.matrixCacheDirectory(for: nil))
        if let userId, !userId.isEmpty {
            try? fm.removeItem(at: LocalDataProtection.matrixDataDirectory(for: userId))
            try? fm.removeItem(at: LocalDataProtection.matrixCacheDirectory(for: userId))
        }
        try? fm.removeItem(at: legacyMatrixDataDirectory())
        try? fm.removeItem(at: legacyMatrixCacheDirectory())
        removeEmptyDirectory(legacyMatrixDataDirectory().deletingLastPathComponent())
        removeEmptyDirectory(legacyMatrixDataDirectory().deletingLastPathComponent().deletingLastPathComponent())
        removeEmptyDirectory(legacyMatrixCacheDirectory().deletingLastPathComponent())
        removeEmptyDirectory(legacyMatrixCacheDirectory().deletingLastPathComponent().deletingLastPathComponent())
        LocalDataProtection.removeMatrixNoSessionStore()
    }

    // MARK: - Login
    // TODO: Remove NSAllowsArbitraryLoads from Info.plist once the server has HTTPS

    func login(username: String, password: String, homeserver: String = Brand.current.defaultHomeserver) async throws {
        stateSubject.send(.loggingIn)

        // Clear stale local state so a fresh login cannot reuse another user's
        // decrypted app cache or Matrix crypto store.
        if let existingUserId = UserDefaults.standard.string(forKey: userIdKey) {
            clearLocalSession(userId: existingUserId)
        } else {
            clearSessionDirectories()
        }

        do {
            let storeConfig = SqliteStoreBuilder(dataPath: sessionDataPath(), cachePath: sessionCachePath())
                .passphrase(passphrase: passphrase)

            let client = try await ClientBuilder()
                .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
                .sqliteStore(config: storeConfig)
                .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
                .setSessionDelegate(sessionDelegate: sessionDelegate)
                .userAgent(userAgent: UserAgentBuilder.makeASCIIUserAgent())
                .requestConfig(config: RequestConfig(retryLimit: 3, timeout: 30000, maxConcurrentRequests: nil, maxRetryTime: nil))
                .autoEnableCrossSigning(autoEnableCrossSigning: true)
                .autoEnableBackups(autoEnableBackups: true)
                .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
                .roomKeyRecipientStrategy(strategy: Self.roomKeyRecipientStrategy)
                .decryptionSettings(decryptionSettings: Self.decryptionSettings)
                .enableShareHistoryOnInvite(enableShareHistoryOnInvite: Self.enableEncryptedHistorySharingOnInvite)
                .build()

            try await client.login(
                username: username,
                password: password,
                initialDeviceName: "Zyna iOS",
                deviceId: nil
            )

            let userId = try client.userId()
            UserDefaults.standard.set(userId, forKey: userIdKey)
            let localSessionId = startNewLocalSessionId()
            activateLocalData(userId: userId)

            // Manually save session — SDK only auto-calls delegate on token refresh
            let session = try client.session()
            sessionDelegate.saveSessionInKeychain(session: session)

            logAuth("Logged in as \(userId) localSession=\(localSessionId)")

            sessionRecoverySession = nil
            sessionRecoveryActive.tryToClearFlag()
            self.client = client
            stateSubject.send(.loggedIn)

            try await startSyncForAuthenticatedSession(
                session: session,
                context: "Login"
            )
        } catch {
            logAuth("Login failed: \(error)")
            stateSubject.send(.error(error))
            throw error
        }
    }

    // MARK: - Session Restore

    func restoreSession() async throws {
        if client != nil {
            guard syncService == nil else {
                stateSubject.send(.syncing)
                return
            }

            let session = currentOrStoredSession()
            try await startSyncForAuthenticatedSession(
                session: session,
                context: "Session sync retry"
            )
            return
        }

        guard let userId = UserDefaults.standard.string(forKey: userIdKey) else {
            logAuth("No stored userId found")
            throw AuthenticationError.sessionNotFound
        }

        let session: MatrixRustSDK.Session
        do {
            session = try sessionDelegate.retrieveSessionFromKeychain(userId: userId)
        } catch {
            logAuth("Stored session unavailable for \(userId): \(error)")
            await enterSessionRecovery(source: .restoreFailure, session: nil, reason: String(describing: error))
            throw error
        }

        do {
            let storeConfig = SqliteStoreBuilder(dataPath: sessionDataPath(), cachePath: sessionCachePath())
                .passphrase(passphrase: passphrase)

            let client = try await ClientBuilder()
                .homeserverUrl(url: session.homeserverUrl)
                .sqliteStore(config: storeConfig)
                .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
                .setSessionDelegate(sessionDelegate: sessionDelegate)
                .userAgent(userAgent: UserAgentBuilder.makeASCIIUserAgent())
                .requestConfig(config: RequestConfig(retryLimit: 3, timeout: 30000, maxConcurrentRequests: nil, maxRetryTime: nil))
                .autoEnableCrossSigning(autoEnableCrossSigning: true)
                .autoEnableBackups(autoEnableBackups: true)
                .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
                .roomKeyRecipientStrategy(strategy: Self.roomKeyRecipientStrategy)
                .decryptionSettings(decryptionSettings: Self.decryptionSettings)
                .enableShareHistoryOnInvite(enableShareHistoryOnInvite: Self.enableEncryptedHistorySharingOnInvite)
                .build()

            try await client.restoreSession(session: session)
            logAuth("Session restored for \(userId)")
            ensureLocalSessionId()
            activateLocalData(userId: userId)
            sessionRecoverySession = nil
            sessionRecoveryActive.tryToClearFlag()

            self.client = client
            stateSubject.send(.loggedIn)
        } catch {
            logAuth("Session restore failed: \(error)")
            if Self.isSoftLogoutError(error) {
                await enterSoftLogout(session: session, reason: String(describing: error))
                throw error
            }
            if Self.isInvalidAccessTokenError(error) {
                await enterSessionRecovery(source: .restoreFailure, session: session, reason: String(describing: error))
                throw error
            }
            if Self.isRetryableTransportError(error) {
                stateSubject.send(.error(error))
                throw error
            }
            await enterSessionRecovery(source: .restoreFailure, session: session, reason: String(describing: error))
            throw error
        }

        try await startSyncForAuthenticatedSession(
            session: session,
            context: "Session restore"
        )
    }

    // MARK: - Sync

    private func startSyncForAuthenticatedSession(
        session: MatrixRustSDK.Session?,
        context: String
    ) async throws {
        do {
            try await startSync()
        } catch {
            let reason = String(describing: error)
            logAuth("\(context) sync start failed: \(error)")

            if Self.isSoftLogoutError(error) {
                if let session {
                    await enterSoftLogout(session: session, reason: reason)
                } else {
                    await enterSoftLogout(reason: reason)
                }
                throw error
            }

            if Self.isInvalidAccessTokenError(error) {
                await enterSessionRecovery(source: .restoreFailure, session: session, reason: reason)
                throw error
            }

            if Self.isRetryableTransportError(error) {
                logAuth("\(context) sync deferred until network recovers: \(error)")
                stateSubject.send(.error(error))
                return
            }

            await enterSessionRecovery(source: .restoreFailure, session: session, reason: reason)
            throw error
        }
    }

    private func startSync() async throws {
        guard let client else { return }
        guard syncService == nil else {
            stateSubject.send(.syncing)
            return
        }

        await attachClientDelegates(to: client)

        // Attach encryption state listeners *before* sync starts so
        // we don't miss the first state delivery from the SDK.
        attachEncryptionListeners()

        let syncService = try await client.syncService().finish()
        let roomListService = syncService.roomListService()

        self.syncService = syncService
        self.roomListService = roomListService

        await client.registerNotificationHandler(listener: CallNotificationListener())

        await syncService.start()
        stateSubject.send(.syncing)
        logSync("Sync started")
    }

    func stopSync() async {
        await syncService?.stop()
        syncService = nil
        roomListService = nil
        logSync("Sync stopped")
    }

    // MARK: - Encryption State Listeners

    /// Attaches verification + recovery state listeners on the
    /// client's encryption module. Both listeners deliver an
    /// initial value shortly after attach. Stored TaskHandles
    /// keep them alive; tearing them down releases the SDK side.
    private func attachEncryptionListeners() {
        guard let client else { return }
        detachEncryptionListeners()

        let encryption = client.encryption()

        let vSync = encryption.verificationState()
        let rSync = encryption.recoveryState()
        logSync("Encryption listeners attaching; sync v=\(vSync) r=\(rSync)")
        verificationStateSubject.send(vSync)
        recoveryStateSubject.send(rSync)

        let vListener = ZynaVerificationStateListener { [weak self] state in
            logSync("verificationState changed: \(state)")
            self?.verificationStateSubject.send(state)
        }
        verificationStateHandle = encryption.verificationStateListener(listener: vListener)

        let rListener = ZynaRecoveryStateListener { [weak self] state in
            logSync("recoveryState changed: \(state)")
            self?.recoveryStateSubject.send(state)
        }
        recoveryStateHandle = encryption.recoveryStateListener(listener: rListener)
    }

    private func detachEncryptionListeners() {
        verificationStateHandle = nil
        recoveryStateHandle = nil
        verificationStateSubject.send(.unknown)
        recoveryStateSubject.send(.unknown)
    }

    // MARK: - Client Delegates

    private func attachClientDelegates(to client: Client) async {
        detachClientDelegates()

        let clientDelegate = ZynaClientDelegate { [weak self] isSoftLogout in
            Task { await self?.handleAuthError(isSoftLogout: isSoftLogout) }
        }

        do {
            clientDelegateHandle = try client.setDelegate(delegate: clientDelegate)
            self.clientDelegate = clientDelegate
        } catch {
            logAuth("Failed to attach client delegate: \(error)")
        }

        let utdDelegate = ZynaUnableToDecryptDelegate()
        do {
            try await client.setUtdDelegate(utdDelegate: utdDelegate)
            self.utdDelegate = utdDelegate
        } catch {
            logSync("Failed to attach UTD delegate: \(error)")
        }
    }

    private func detachClientDelegates() {
        clientDelegateHandle = nil
        clientDelegate = nil
        utdDelegate = nil
    }

    // MARK: - Logout

    func enableKeyBackup() async throws {
        guard let client else {
            throw AuthenticationError.clientNotInitialized
        }

        let encryption = client.encryption()

        do {
            if try await encryption.backupExistsOnServer() {
                logRecoveryReset("Server key backup already exists; recovery key is required to reconnect it")
                throw BackupUploadWaitFailure.backupDisabled
            }
        } catch let failure as BackupUploadWaitFailure {
            throw failure
        } catch {
            logRecoveryReset("Failed to check whether encryption key backup exists on server: \(error)")
            throw BackupUploadWaitFailure.unknown
        }

        logRecoveryReset("Enabling encryption key backup")
        do {
            try await encryption.enableBackups()
            logRecoveryReset("Encryption key backup enabled")
        } catch RecoveryError.BackupExistsOnServer {
            logRecoveryReset("Failed to enable encryption key backup: backup already exists on server")
            throw BackupUploadWaitFailure.backupDisabled
        } catch {
            logRecoveryReset("Failed to enable encryption key backup: \(error)")
            throw BackupUploadWaitFailure.unknown
        }
    }

    func waitForBackupUploadSteadyState() async throws {
        guard let client else {
            throw AuthenticationError.clientNotInitialized
        }

        logRecoveryReset("Waiting for encryption key backup upload steady state")
        let listener = ZynaBackupSteadyStateListener { state in
            logRecoveryReset("Backup upload state: \(Self.describeBackupUploadState(state))")
        }
        do {
            try await client.encryption().waitForBackupUploadSteadyState(progressListener: listener)
            logRecoveryReset("Encryption key backup upload reached steady state")
        } catch let error as SteadyStateError {
            logRecoveryReset("Encryption key backup upload wait failed: \(error)")
            switch error {
            case .BackupDisabled:
                throw BackupUploadWaitFailure.backupDisabled
            case .Connection:
                throw BackupUploadWaitFailure.connection
            case .Lagged:
                throw BackupUploadWaitFailure.lagged
            }
        } catch {
            logRecoveryReset("Encryption key backup upload wait failed: \(error)")
            throw BackupUploadWaitFailure.unknown
        }
    }

    func logoutFromServer() async throws {
        guard let client else {
            throw AuthenticationError.clientNotInitialized
        }

        do {
            try await client.logout()
            logAuth("Server logout completed")
        } catch {
            logAuth("Server logout failed: \(error)")
            throw error
        }
    }

    func logoutLocally() async {
        let userId = currentOrStoredUserId(client: client)

        await stopSync()
        detachEncryptionListeners()
        detachClientDelegates()

        client = nil
        sessionRecoverySession = nil
        sessionRecoveryActive.tryToClearFlag()
        clearLocalSession(userId: userId)
        stateSubject.send(.loggedOut)
        logAuth("Logged out locally")
    }

    func logout() async {
        do {
            try await waitForBackupUploadSteadyState()
        } catch {
            logAuth("Logout aborted because encryption key backup steady state was not confirmed: \(error)")
            return
        }

        do {
            try await logoutFromServer()
        } catch {
            logAuth("Continuing with local logout after server logout failure: \(error)")
        }
        await logoutLocally()
    }

    @discardableResult
    func handleInvalidAccessTokenIfNeeded(_ error: Error) async -> Bool {
        guard Self.isInvalidAccessTokenError(error) else {
            return false
        }

        let reason = String(describing: error)
        if Self.isSoftLogoutError(error) {
            await enterSoftLogout(reason: reason)
        } else {
            await invalidateLocalSession(reason: reason)
        }
        return true
    }

    private func handleAuthError(isSoftLogout: Bool) async {
        if isSoftLogout {
            await enterSoftLogout(reason: "SDK auth error softLogout=true")
        } else {
            await invalidateLocalSession(reason: "SDK auth error softLogout=false")
        }
    }

    private func enterSoftLogout(reason: String) async {
        guard let session = currentOrStoredSession() else {
            logAuth("Soft logout requested but no session was available; preserving local crypto store. reason=\(reason)")
            await enterSessionRecovery(source: .softLogout, session: nil, reason: reason)
            return
        }
        await enterSoftLogout(session: session, reason: reason)
    }

    private func enterSoftLogout(session: MatrixRustSDK.Session, reason: String) async {
        await enterSessionRecovery(source: .softLogout, session: session, reason: reason)
    }

    private func enterSessionRecovery(source: SessionRecoverySource, session: MatrixRustSDK.Session?, reason: String) async {
        if let session { sessionRecoverySession = session }
        sessionRecoverySource = source
        guard sessionRecoveryActive.tryToSetFlag() else {
            stateSubject.send(sessionRecoverySource.state)
            return
        }

        let userId = session?.userId ?? UserDefaults.standard.string(forKey: userIdKey) ?? "unknown"
        logAuth("\(source.logPrefix); preserving local crypto store for \(userId). reason=\(reason)")
        await stopSync()
        detachEncryptionListeners()
        detachClientDelegates()
        client = nil
        stateSubject.send(sessionRecoverySource.state)
    }

    func loginAfterSoftLogout(password: String) async throws {
        try await loginAfterSessionRecovery(password: password)
    }

    func loginAfterSessionRecovery(password: String) async throws {
        guard let session = currentOrStoredSession() else {
            throw AuthenticationError.sessionNotFound
        }

        let recoveryStateOnFailure = sessionRecoverySource.state
        stateSubject.send(.loggingIn)

        do {
            let storeConfig = SqliteStoreBuilder(dataPath: sessionDataPath(), cachePath: sessionCachePath())
                .passphrase(passphrase: passphrase)

            let client = try await ClientBuilder()
                .homeserverUrl(url: session.homeserverUrl)
                .sqliteStore(config: storeConfig)
                .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
                .setSessionDelegate(sessionDelegate: sessionDelegate)
                .userAgent(userAgent: UserAgentBuilder.makeASCIIUserAgent())
                .requestConfig(config: RequestConfig(retryLimit: 3, timeout: 30000, maxConcurrentRequests: nil, maxRetryTime: nil))
                .autoEnableCrossSigning(autoEnableCrossSigning: true)
                .autoEnableBackups(autoEnableBackups: true)
                .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
                .roomKeyRecipientStrategy(strategy: Self.roomKeyRecipientStrategy)
                .decryptionSettings(decryptionSettings: Self.decryptionSettings)
                .enableShareHistoryOnInvite(enableShareHistoryOnInvite: Self.enableEncryptedHistorySharingOnInvite)
                .build()

            try await client.login(
                username: session.userId,
                password: password,
                initialDeviceName: "Zyna iOS",
                deviceId: session.deviceId
            )

            let refreshedSession = try client.session()
            UserDefaults.standard.set(refreshedSession.userId, forKey: userIdKey)
            ensureLocalSessionId()
            activateLocalData(userId: refreshedSession.userId)
            sessionDelegate.saveSessionInKeychain(session: refreshedSession)

            sessionRecoverySession = refreshedSession
            sessionRecoveryActive.tryToClearFlag()
            self.client = client
            try await startSyncForAuthenticatedSession(
                session: refreshedSession,
                context: "Session recovery sign-in"
            )

            sessionRecoverySession = nil
            logAuth("Session recovery sign-in succeeded for \(refreshedSession.userId) device=\(refreshedSession.deviceId)")
        } catch {
            logAuth("Session recovery sign-in failed: \(error)")
            stateSubject.send(recoveryStateOnFailure)
            throw error
        }
    }

    func simulateSoftLogoutForDiagnostics() async throws {
        guard let session = currentOrStoredSession() else {
            throw AuthenticationError.sessionNotFound
        }
        await enterSoftLogout(session: session, reason: "Debug simulation")
    }

    // MARK: - OAuth

    // TODO: Replace with https://markovsdima.github.io/oidc/callback + Associated Domains once Apple Developer Account is active
    private static let oauthRedirectURI = "zyna://oidc/callback"

    private static let oauthConfig = OAuthConfiguration(
        clientName: "Zyna",
        redirectUri: oauthRedirectURI,
        clientUri: "https://github.com/markovsdima/Zyna",
        logoUri: nil,
        tosUri: nil,
        policyUri: nil,
        staticRegistrations: [:]
    )

    /// Build a client for a given homeserver (without logging in).
    func buildUnauthenticatedClient(homeserver: String) async throws -> Client {
        if let existingUserId = UserDefaults.standard.string(forKey: userIdKey) {
            clearLocalSession(userId: existingUserId)
        } else {
            clearSessionDirectories()
        }

        let storeConfig = SqliteStoreBuilder(dataPath: sessionDataPath(), cachePath: sessionCachePath())
            .passphrase(passphrase: passphrase)

        return try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sqliteStore(config: storeConfig)
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            .userAgent(userAgent: UserAgentBuilder.makeASCIIUserAgent())
            .requestConfig(config: RequestConfig(retryLimit: 3, timeout: 30000, maxConcurrentRequests: nil, maxRetryTime: nil))
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .autoEnableBackups(autoEnableBackups: true)
            .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
            .roomKeyRecipientStrategy(strategy: Self.roomKeyRecipientStrategy)
            .decryptionSettings(decryptionSettings: Self.decryptionSettings)
            .enableShareHistoryOnInvite(enableShareHistoryOnInvite: Self.enableEncryptedHistorySharingOnInvite)
            .build()
    }

    /// Start an OAuth authentication flow. Returns the login URL and authorization data.
    func startOAuthFlow(client: Client) async throws -> (loginURL: URL, authData: OAuthAuthorizationData) {
        let authData = try await client.urlForOauth(
            oauthConfiguration: Self.oauthConfig,
            prompt: .consent,
            loginHint: nil,
            deviceId: nil,
            additionalScopes: nil
        )
        guard let url = URL(string: authData.loginUrl()) else {
            throw AuthenticationError.invalidOAuthURL
        }
        return (url, authData)
    }

    /// Complete an OAuth flow after receiving the callback URL from the browser.
    func completeOAuthFlow(client: Client, callbackURL: String) async throws {
        try await client.loginWithOauthCallback(callbackUrl: callbackURL)

        let userId = try client.userId()
        UserDefaults.standard.set(userId, forKey: userIdKey)
        let localSessionId = startNewLocalSessionId()
        activateLocalData(userId: userId)

        let session = try client.session()
        sessionDelegate.saveSessionInKeychain(session: session)

        logAuth("OAuth login successful as \(userId) localSession=\(localSessionId)")

        self.client = client
        stateSubject.send(.loggedIn)

        try await startSyncForAuthenticatedSession(
            session: session,
            context: "OAuth login"
        )
    }

    var hasStoredSession: Bool {
        UserDefaults.standard.string(forKey: userIdKey) != nil
    }

    var currentLocalSessionId: String? {
        UserDefaults.standard.string(forKey: localSessionIdKey)
    }

    var sessionRecoveryCredentials: SessionRecoveryCredentials? {
        if let session = currentOrStoredSession() {
            return SessionRecoveryCredentials(
                userId: session.userId,
                deviceId: session.deviceId,
                homeserverUrl: session.homeserverUrl,
                canSignIn: true
            )
        }
        guard let userId = UserDefaults.standard.string(forKey: userIdKey) else {
            return nil
        }
        return SessionRecoveryCredentials(
            userId: userId,
            deviceId: nil,
            homeserverUrl: nil,
            canSignIn: false
        )
    }

    var softLogoutCredentials: SessionRecoveryCredentials? {
        sessionRecoveryCredentials
    }

    private func currentOrStoredSession() -> MatrixRustSDK.Session? {
        if let session = sessionRecoverySession {
            return session
        }
        if let client, let session = try? client.session() {
            return session
        }
        guard let userId = UserDefaults.standard.string(forKey: userIdKey) else {
            return nil
        }
        return try? sessionDelegate.retrieveSessionFromKeychain(userId: userId)
    }

    private func currentOrStoredUserId(client: Client?) -> String? {
        if let client, let userId = try? client.userId(), !userId.isEmpty {
            return userId
        }
        return UserDefaults.standard.string(forKey: userIdKey)
    }

    private func activateLocalData(userId: String) {
        DatabaseService.shared.activate(userId: userId)
        FileCacheService.shared.activate(userId: userId)
        MediaCache.shared.activate(userId: userId)
        LocalDataProtection.removeLegacyGlobalLocalData()
    }

    private func clearAppLocalData(userId: String?) {
        DatabaseService.shared.closeForLocalDataRemoval(userId: userId)
        FileCacheService.shared.clearAll(userId: userId)
        MediaCache.shared.clearAll(userId: userId)

        if let userId, !userId.isEmpty {
            LocalDataProtection.removeUserLocalData(userId: userId)
            DatabasePassphraseStore.removePassphrase(for: userId)
        } else {
            LocalDataProtection.removeAllUserLocalData()
            DatabasePassphraseStore.removeAllPassphrases()
        }

        LocalDataProtection.removeLegacyGlobalLocalData()
        LocalDataProtection.removeTemporaryLocalData()
        DatabaseService.shared.activate(userId: nil)
        FileCacheService.shared.activate(userId: nil)
        MediaCache.shared.activate(userId: nil)
    }

    private func clearLocalSession(userId: String?) {
        if let userId, !userId.isEmpty {
            sessionDelegate.clearSession(userId: userId)
            SessionVerificationService.clearLocalEncryptionFlags(userId: userId)
        } else {
            sessionDelegate.clearAllSessions()
        }
        UserDefaults.standard.removeObject(forKey: userIdKey)
        UserDefaults.standard.removeObject(forKey: localSessionIdKey)
        clearSessionDirectories(userId: userId)
        clearAppLocalData(userId: userId)
    }

    @discardableResult
    private func startNewLocalSessionId() -> String {
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: localSessionIdKey)
        return id
    }

    @discardableResult
    private func ensureLocalSessionId() -> String {
        if let existing = currentLocalSessionId {
            return existing
        }
        return startNewLocalSessionId()
    }

    private func invalidateLocalSession(reason: String) async {
        guard invalidatingSession.tryToSetFlag() else { return }
        defer { invalidatingSession.tryToClearFlag() }

        logAuth("Invalid access token; preserving local crypto store for session recovery: \(reason)")
        if let session = currentOrStoredSession() {
            await enterSessionRecovery(source: .restoreFailure, session: session, reason: reason)
        } else {
            await enterSessionRecovery(source: .restoreFailure, session: nil, reason: reason)
        }
    }

    private static func isInvalidAccessTokenError(_ error: Error) -> Bool {
        let description = String(describing: error)
        return description.contains("M_UNKNOWN_TOKEN")
            || description.contains("UnknownToken")
            || description.contains("Invalid access token")
    }

    private static func isSoftLogoutError(_ error: Error) -> Bool {
        let compactDescription = String(describing: error)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return compactDescription.contains("soft_logout:true")
            || compactDescription.contains("soft_logout\":true")
            || compactDescription.contains("soft_logout=true")
            || compactDescription.contains("softlogout:true")
            || compactDescription.contains("softlogout=true")
    }

    static func isRetryableTransportError(_ error: Error) -> Bool {
        if isInvalidAccessTokenError(error) || isSoftLogoutError(error) {
            return false
        }

        let nsError = error as NSError
        if isRetryableURLError(nsError) {
            return true
        }

        let errorText = [
            String(reflecting: error),
            String(describing: error),
            nsError.localizedDescription
        ]
        .joined(separator: "\n")
        .lowercased()

        return [
            "not connected to internet",
            "notconnectedtointernet",
            "internet connection appears to be offline",
            "network connection lost",
            "networkconnectionlost",
            "network is unreachable",
            "no route to host",
            "cannot find host",
            "cannotfindhost",
            "cannot connect to host",
            "cannotconnecttohost",
            "connection lost",
            "connection refused",
            "connection reset",
            "dns",
            "timed out",
            "timeout",
            "temporarily unavailable",
            "service unavailable",
            "bad gateway",
            "gateway timeout",
            "server error",
            "servererror",
            "request error",
            "error sending request",
            "reqwest",
            "hyper",
            "transport"
        ].contains { errorText.contains($0) }
    }

    private static func isRetryableURLError(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorCannotLoadFromNetwork:
                return true
            default:
                break
            }
        }

        guard depth < 4,
              let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isRetryableURLError(underlying, depth: depth + 1)
    }

    private static func describeBackupUploadState(_ state: BackupUploadState) -> String {
        switch state {
        case .waiting:
            return "waiting"
        case .uploading(let backedUpCount, let totalCount):
            return "uploading \(backedUpCount)/\(totalCount)"
        case .error:
            return "error"
        case .done:
            return "done"
        }
    }

}

// MARK: - SDK Listener Adapters

private final class ZynaVerificationStateListener: VerificationStateListener {
    private let handler: @Sendable (VerificationState) -> Void
    init(handler: @escaping @Sendable (VerificationState) -> Void) { self.handler = handler }
    func onUpdate(status: VerificationState) { handler(status) }
}

private final class ZynaRecoveryStateListener: RecoveryStateListener {
    private let handler: @Sendable (RecoveryState) -> Void
    init(handler: @escaping @Sendable (RecoveryState) -> Void) { self.handler = handler }
    func onUpdate(status: RecoveryState) { handler(status) }
}

private final class ZynaBackupSteadyStateListener: BackupSteadyStateListener {
    private let handler: @Sendable (BackupUploadState) -> Void

    init(handler: @escaping @Sendable (BackupUploadState) -> Void) {
        self.handler = handler
    }

    func onUpdate(status: BackupUploadState) {
        handler(status)
    }
}

private final class ZynaClientDelegate: ClientDelegate {
    private let authErrorHandler: @Sendable (Bool) -> Void

    init(authErrorHandler: @escaping @Sendable (Bool) -> Void) {
        self.authErrorHandler = authErrorHandler
    }

    func didReceiveAuthError(isSoftLogout: Bool) {
        logAuth("SDK auth error received; softLogout=\(isSoftLogout)")
        authErrorHandler(isSoftLogout)
    }

    func onBackgroundTaskErrorReport(taskName: String, error: BackgroundTaskFailureReason) {
        logSync("SDK background task failed task=\(taskName) error=\(error)")
    }
}

private final class ZynaUnableToDecryptDelegate: UnableToDecryptDelegate {
    func onUtd(info: UnableToDecryptInfo) {
        let timeToDecrypt = info.timeToDecryptMs.map(String.init) ?? "nil"
        logSync(
            "UTD report eventId=\(info.eventId) cause=\(info.cause) timeToDecryptMs=\(timeToDecrypt) " +
            "eventLocalAgeMs=\(info.eventLocalAgeMillis) trustsOwnIdentity=\(info.userTrustsOwnIdentity) " +
            "senderHs=\(info.senderHomeserver) ownHs=\(info.ownHomeserver ?? "nil")"
        )
    }
}
