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
    case error(Error)
}

struct SoftLogoutCredentials {
    let userId: String
    let deviceId: String
    let homeserverUrl: String
}

private let logAuth = ScopedLog(.auth)
private let logSync = ScopedLog(.sync)

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
    private var softLogoutSession: MatrixRustSDK.Session?
    private let invalidatingSession = Atomic(false)
    private let softLogoutActive = Atomic(false)

    private let userIdKey = "com.zyna.matrix.lastUserId"
    private let localSessionIdKey = "com.zyna.matrix.localSessionId"
    private static let passphraseKeychainKey = "com.zyna.matrix.storePassphrase"

    private init() {
        let keychain = Keychain(service: "com.zyna.matrix.crypto")
            .accessibility(.whenUnlockedThisDeviceOnly)

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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("matrix/data/\(userId ?? "default")")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func sessionCachePath(for userId: String? = nil) -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("matrix/cache/\(userId ?? "default")")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Removes session data/cache directories so a fresh login doesn't collide
    /// with a previous device's crypto store.
    private func clearSessionDirectories() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: sessionDataPath())
        try? fm.removeItem(atPath: sessionCachePath())
    }

    // MARK: - Login
    // TODO: Remove NSAllowsArbitraryLoads from Info.plist once the server has HTTPS

    func login(username: String, password: String, homeserver: String = Brand.current.defaultHomeserver) async throws {
        stateSubject.send(.loggingIn)

        // Clear stale crypto store and verification flag so the
        // verification screen shows after a fresh login.
        clearSessionDirectories()
        if let existingUserId = UserDefaults.standard.string(forKey: userIdKey) {
            SessionVerificationService.clearLocalSecretsFlag(userId: existingUserId)
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

            // Manually save session — SDK only auto-calls delegate on token refresh
            let session = try client.session()
            sessionDelegate.saveSessionInKeychain(session: session)

            logAuth("Logged in as \(userId) localSession=\(localSessionId)")

            softLogoutSession = nil
            softLogoutActive.tryToClearFlag()
            self.client = client
            stateSubject.send(.loggedIn)

            try await startSync()
        } catch {
            logAuth("Login failed: \(error)")
            stateSubject.send(.error(error))
            throw error
        }
    }

    // MARK: - Session Restore

    func restoreSession() async throws {
        guard let userId = UserDefaults.standard.string(forKey: userIdKey) else {
            logAuth("No stored userId found")
            throw AuthenticationError.sessionNotFound
        }

        let session: MatrixRustSDK.Session
        do {
            session = try sessionDelegate.retrieveSessionFromKeychain(userId: userId)
        } catch {
            logAuth("Stored session unavailable for \(userId): \(error)")
            clearLocalSession(userId: userId)
            FileCacheService.shared.clearAll()
            stateSubject.send(.loggedOut)
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
                .build()

            try await client.restoreSession(session: session)
            logAuth("Session restored for \(userId)")
            ensureLocalSessionId()

            self.client = client
            stateSubject.send(.loggedIn)

            try await startSync()
        } catch {
            logAuth("Session restore failed: \(error)")
            if Self.isSoftLogoutError(error) {
                await enterSoftLogout(session: session, reason: String(describing: error))
                throw error
            }
            await stopSync()
            detachEncryptionListeners()
            detachClientDelegates()
            client = nil
            clearLocalSession(userId: userId)
            FileCacheService.shared.clearAll()
            stateSubject.send(.loggedOut)
            throw error
        }
    }

    // MARK: - Sync

    private func startSync() async throws {
        guard let client else { return }

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
        softLogoutSession = nil
        softLogoutActive.tryToClearFlag()
        clearLocalSession(userId: userId)
        FileCacheService.shared.clearAll()
        stateSubject.send(.loggedOut)
        logAuth("Logged out locally")
    }

    func logout() async {
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
            logAuth("Soft logout requested but no session was available; clearing local session")
            await invalidateLocalSession(reason: reason)
            return
        }
        await enterSoftLogout(session: session, reason: reason)
    }

    private func enterSoftLogout(session: MatrixRustSDK.Session, reason: String) async {
        softLogoutSession = session
        guard softLogoutActive.tryToSetFlag() else { return }

        logAuth("Soft logout; preserving local crypto store for \(session.userId). reason=\(reason)")
        await stopSync()
        detachEncryptionListeners()
        detachClientDelegates()
        client = nil
        stateSubject.send(.softLoggedOut)
    }

    func loginAfterSoftLogout(password: String) async throws {
        guard let session = currentOrStoredSession() else {
            throw AuthenticationError.sessionNotFound
        }

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
            sessionDelegate.saveSessionInKeychain(session: refreshedSession)

            softLogoutSession = refreshedSession
            softLogoutActive.tryToClearFlag()
            self.client = client
            do {
                try await startSync()
            } catch {
                await stopSync()
                detachEncryptionListeners()
                detachClientDelegates()
                self.client = nil
                softLogoutSession = refreshedSession
                _ = softLogoutActive.tryToSetFlag()
                throw error
            }

            softLogoutSession = nil
            logAuth("Soft logout re-login succeeded for \(refreshedSession.userId) device=\(refreshedSession.deviceId)")
        } catch {
            logAuth("Soft logout re-login failed: \(error)")
            stateSubject.send(.softLoggedOut)
            throw error
        }
    }

    func simulateSoftLogoutForDiagnostics() async throws {
        guard let session = currentOrStoredSession() else {
            throw AuthenticationError.sessionNotFound
        }
        await enterSoftLogout(session: session, reason: "Debug simulation")
    }

    // MARK: - OIDC

    // TODO: Replace with https://markovsdima.github.io/oidc/callback + Associated Domains once Apple Developer Account is active
    private static let oidcRedirectURI = "zyna://oidc/callback"

    private static let oidcConfig = OidcConfiguration(
        clientName: "Zyna",
        redirectUri: oidcRedirectURI,
        clientUri: "https://github.com/markovsdima/Zyna",
        logoUri: nil,
        tosUri: nil,
        policyUri: nil,
        staticRegistrations: [:]
    )

    /// Build a client for a given homeserver (without logging in).
    func buildUnauthenticatedClient(homeserver: String) async throws -> Client {
        clearSessionDirectories()

        let storeConfig = SqliteStoreBuilder(dataPath: sessionDataPath(), cachePath: sessionCachePath())
            .passphrase(passphrase: passphrase)

        return try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sqliteStore(config: storeConfig)
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            .userAgent(userAgent: UserAgentBuilder.makeASCIIUserAgent())
            .requestConfig(config: RequestConfig(retryLimit: 3, timeout: 30000, maxConcurrentRequests: nil, maxRetryTime: nil))
            .build()
    }

    /// Start an OIDC authentication flow. Returns the login URL and authorization data.
    func startOIDCFlow(client: Client) async throws -> (loginURL: URL, authData: OAuthAuthorizationData) {
        let authData = try await client.urlForOidc(
            oidcConfiguration: Self.oidcConfig,
            prompt: .consent,
            loginHint: nil,
            deviceId: nil,
            additionalScopes: nil
        )
        guard let url = URL(string: authData.loginUrl()) else {
            throw AuthenticationError.invalidOIDCURL
        }
        return (url, authData)
    }

    /// Complete an OIDC flow after receiving the callback URL from the browser.
    func completeOIDCFlow(client: Client, callbackURL: String) async throws {
        try await client.loginWithOidcCallback(callbackUrl: callbackURL)

        let userId = try client.userId()
        UserDefaults.standard.set(userId, forKey: userIdKey)
        let localSessionId = startNewLocalSessionId()

        let session = try client.session()
        sessionDelegate.saveSessionInKeychain(session: session)

        logAuth("OIDC login successful as \(userId) localSession=\(localSessionId)")

        self.client = client
        stateSubject.send(.loggedIn)

        try await startSync()
    }

    var hasStoredSession: Bool {
        UserDefaults.standard.string(forKey: userIdKey) != nil
    }

    var currentLocalSessionId: String? {
        UserDefaults.standard.string(forKey: localSessionIdKey)
    }

    var softLogoutCredentials: SoftLogoutCredentials? {
        guard let session = currentOrStoredSession() else { return nil }
        return SoftLogoutCredentials(
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl
        )
    }

    private func currentOrStoredSession() -> MatrixRustSDK.Session? {
        if let session = softLogoutSession {
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

    private func clearLocalSession(userId: String?) {
        if let userId, !userId.isEmpty {
            sessionDelegate.clearSession(userId: userId)
            SessionVerificationService.clearLocalSecretsFlag(userId: userId)
        } else {
            sessionDelegate.clearAllSessions()
        }
        UserDefaults.standard.removeObject(forKey: userIdKey)
        UserDefaults.standard.removeObject(forKey: localSessionIdKey)
        clearSessionDirectories()
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

        logAuth("Invalid access token; clearing local session: \(reason)")
        await logoutLocally()
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

}

// MARK: - SDK Listener Adapters

private final class ZynaVerificationStateListener: VerificationStateListener {
    private let handler: (VerificationState) -> Void
    init(handler: @escaping (VerificationState) -> Void) { self.handler = handler }
    func onUpdate(status: VerificationState) { handler(status) }
}

private final class ZynaRecoveryStateListener: RecoveryStateListener {
    private let handler: (RecoveryState) -> Void
    init(handler: @escaping (RecoveryState) -> Void) { self.handler = handler }
    func onUpdate(status: RecoveryState) { handler(status) }
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
