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
    case error(Error)
}

private let authLog = ScopedLog(.auth)
private let syncLog = ScopedLog(.sync)

// MARK: - Matrix Client Service

final class MatrixClientService {

    static let shared = MatrixClientService()

    // MARK: - Published State

    let stateSubject = CurrentValueSubject<MatrixClientState, Never>(.loggedOut)
    var state: MatrixClientState { stateSubject.value }

    // MARK: - SDK Objects

    private(set) var client: Client?
    private(set) var syncService: SyncService?
    private(set) var roomListService: RoomListService?

    // MARK: - Private

    private let sessionDelegate = DefaultSessionDelegate()
    private let passphrase: String
    private var syncStateHandle: TaskHandle?

    private let userIdKey = "com.zyna.matrix.lastUserId"
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

    func login(username: String, password: String, homeserver: String = "matrix.org") async throws {
        stateSubject.send(.loggingIn)

        // Clear stale crypto store to avoid device ID mismatch
        clearSessionDirectories()

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
                .build()

            try await client.login(
                username: username,
                password: password,
                initialDeviceName: "Zyna iOS",
                deviceId: nil
            )

            let userId = try client.userId()
            UserDefaults.standard.set(userId, forKey: userIdKey)

            // Manually save session — SDK only auto-calls delegate on token refresh
            let session = try client.session()
            sessionDelegate.saveSessionInKeychain(session: session)

            authLog("Logged in as \(userId)")

            self.client = client
            stateSubject.send(.loggedIn)

            try await startSync()
        } catch {
            authLog("Login failed: \(error)")
            stateSubject.send(.error(error))
            throw error
        }
    }

    // MARK: - Session Restore

    func restoreSession() async throws {
        guard let userId = UserDefaults.standard.string(forKey: userIdKey) else {
            authLog("No stored userId found")
            throw AuthenticationError.sessionNotFound
        }

        do {
            let session = try sessionDelegate.retrieveSessionFromKeychain(userId: userId)

            let storeConfig = SqliteStoreBuilder(dataPath: sessionDataPath(), cachePath: sessionCachePath())
                .passphrase(passphrase: passphrase)

            let client = try await ClientBuilder()
                .homeserverUrl(url: session.homeserverUrl)
                .sqliteStore(config: storeConfig)
                .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
                .setSessionDelegate(sessionDelegate: sessionDelegate)
                .userAgent(userAgent: UserAgentBuilder.makeASCIIUserAgent())
                .requestConfig(config: RequestConfig(retryLimit: 3, timeout: 30000, maxConcurrentRequests: nil, maxRetryTime: nil))
                .build()

            try await client.restoreSession(session: session)
            authLog("Session restored for \(userId)")

            self.client = client
            stateSubject.send(.loggedIn)

            try await startSync()
        } catch {
            authLog("Session restore failed: \(error)")
            stateSubject.send(.error(error))
            throw error
        }
    }

    // MARK: - Sync

    private func startSync() async throws {
        guard let client else { return }

        let syncService = try await client.syncService().finish()
        let roomListService = syncService.roomListService()

        self.syncService = syncService
        self.roomListService = roomListService

        await syncService.start()
        stateSubject.send(.syncing)
        syncLog("Sync started")
    }

    func stopSync() async {
        await syncService?.stop()
        syncService = nil
        roomListService = nil
        syncLog("Sync stopped")
    }

    // MARK: - Logout

    func logout() async {
        await stopSync()

        if let client {
            let userId = (try? client.userId()) ?? ""
            try? await client.logout()
            sessionDelegate.clearSession(userId: userId)
            UserDefaults.standard.removeObject(forKey: userIdKey)
            authLog("Logged out")
        }

        self.client = nil
        stateSubject.send(.loggedOut)
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

        let session = try client.session()
        sessionDelegate.saveSessionInKeychain(session: session)

        authLog("OIDC login successful as \(userId)")

        self.client = client
        stateSubject.send(.loggedIn)

        try await startSync()
    }

    // MARK: - Helpers

    var hasStoredSession: Bool {
        UserDefaults.standard.string(forKey: userIdKey) != nil
    }
}
