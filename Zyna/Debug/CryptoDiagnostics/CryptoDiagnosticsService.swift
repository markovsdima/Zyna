//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import Foundation
import MatrixRustSDK
@preconcurrency import KeychainAccess

/// Read-only inspection and controlled failure simulation for the Matrix
/// crypto store / keychain split.
///
/// IMPORTANT: destructive operations must run with NO live Matrix `Client`
/// holding the store open. That is why this tool launches instead of the app
/// (see `SceneDelegate`), never as an in-app menu.
enum CryptoDiagnosticsService {

    // Mirrors the constants used by MatrixClientService / the NSE.
    private static let appGroupIdentifier = "group.com.app.zyna"
    private static let matrixLastUserIdKey = "com.zyna.matrix.lastUserId"
    private static let sessionService = "com.zyna.matrix.session"
    private static let passphraseService = "com.zyna.matrix.crypto"
    private static let passphraseKey = "com.zyna.matrix.storePassphrase"
    private static let cryptoIdentityFingerprintKey = "com.zyna.matrix.cryptoIdentityFingerprint"
    private static let matrixCryptoStoreDatabaseName = "matrix-sdk-crypto.sqlite3"
    private static let matrixStateStoreDatabaseName = "matrix-sdk-state.sqlite3"
    private static let lockHolder = "com.app.zyna.diagnostics"

    private struct StoredSessionData: Codable {
        let accessToken: String
        let refreshToken: String?
        let userId: String
        let deviceId: String
        let homeserverUrl: String
        let oauthData: String?
    }

    private struct LocalCryptoIdentityFingerprint: Codable, Equatable {
        let userId: String
        let deviceId: String
        let curve25519Key: String
        let ed25519Key: String
    }

    fileprivate struct DirectoryEntry {
        let name: String
        let isDirectory: Bool
        let size: Int
        let modified: Date?
    }

    fileprivate struct DirectorySnapshot {
        let label: String
        let url: URL
        let exists: Bool
        let isDirectory: Bool
        let entries: [DirectoryEntry]

        var hasContents: Bool {
            exists && isDirectory && !entries.isEmpty
        }

        func file(named name: String) -> DirectoryEntry? {
            entries.first { $0.name == name && !$0.isDirectory }
        }
    }

    private struct ServerKeysQueryRequest: Encodable {
        let deviceKeys: [String: [String]]
        let timeout: Int

        enum CodingKeys: String, CodingKey {
            case deviceKeys = "device_keys"
            case timeout
        }
    }

    private struct ServerKeysQueryResponse: Decodable {
        let deviceKeys: [String: [String: ServerDeviceKeys]]

        enum CodingKeys: String, CodingKey {
            case deviceKeys = "device_keys"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceKeys = (try? container.decode([String: [String: ServerDeviceKeys]].self, forKey: .deviceKeys)) ?? [:]
        }
    }

    private struct ServerDeviceKeys: Decodable {
        let userId: String
        let deviceId: String
        let keys: [String: String]

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case deviceId = "device_id"
            case keys
        }

        func identityKeys(for expectedDeviceId: String) -> (curve25519: String?, ed25519: String?) {
            (
                keys["curve25519:\(expectedDeviceId)"],
                keys["ed25519:\(expectedDeviceId)"]
            )
        }
    }

    // MARK: - Safe reports

    static func safeSnapshot() -> String {
        [
            reportHeader(),
            storeHealthSnapshot(),
            nseReadinessReport(),
            inspectKeychainSession(),
            inspectUserDefaults(),
            fingerprintReport(),
            MatrixRustSDKTracing.statusReport()
        ].joined(separator: "\n\n")
    }

    static func tracingStatusReport() -> String {
        MatrixRustSDKTracing.statusReport()
    }

    static func tracingLogFiles() -> [URL] {
        MatrixRustSDKTracing.logFiles()
    }

    static func clearTracingLogs() -> String {
        MatrixRustSDKTracing.clearLogs()
    }

    static func storeHealthSnapshot() -> String {
        let session = selectedStoredSession()?.session
        var out = "Store health\n"
        out += "selectedUserId=\(session?.userId ?? "<nil>") selectedDeviceId=\(session?.deviceId ?? "<nil>")\n"

        let dataSnapshots = matrixDataDirectorySnapshots(for: session?.userId)
        let cacheSnapshots = matrixCacheDirectorySnapshots(for: session?.userId)

        out += "\n[data candidates]\n"
        for snapshot in dataSnapshots {
            out += renderDirectorySummary(snapshot) + "\n"
        }

        out += "\n[cache candidates]\n"
        for snapshot in cacheSnapshots {
            out += renderDirectorySummary(snapshot) + "\n"
        }

        let sharedData = directorySnapshot(label: "shared data", url: LocalDataProtection.sharedMatrixDataDirectory())
        let sharedCache = directorySnapshot(label: "shared cache", url: LocalDataProtection.sharedMatrixCacheDirectory())
        let appRestoreWouldAllow = dataSnapshots.contains { matrixCryptoStoreExists(in: $0.url) }
        let nseWouldAllow = sharedData.hasContents && sharedCache.hasContents && matrixCryptoStoreExists(in: sharedData.url)

        out += "\n[verdict]\n"
        out += "app restore guard: \(appRestoreWouldAllow ? "ALLOW" : "BLOCK")"
        out += " (requires \(matrixCryptoStoreDatabaseName) in shared or migration-source data store)\n"
        out += "NSE restore guard: \(nseWouldAllow ? "ALLOW" : "BLOCK")"
        out += " (requires shared data/cache + shared \(matrixCryptoStoreDatabaseName))\n"

        if sharedData.file(named: matrixCryptoStoreDatabaseName) == nil,
           dataSnapshots.contains(where: { $0.label != sharedData.label && matrixCryptoStoreExists(in: $0.url) }) {
            out += "\nNote: a legacy/user crypto DB exists, but shared crypto DB is missing. The app restore path may migrate it; diagnostics refuses to open an empty shared store."
        }

        return out
    }

    static func nseReadinessReport() -> String {
        let sharedData = directorySnapshot(label: "shared data", url: LocalDataProtection.sharedMatrixDataDirectory())
        let sharedCache = directorySnapshot(label: "shared cache", url: LocalDataProtection.sharedMatrixCacheDirectory())
        let session = selectedStoredSession()?.session
        let passphrasePresent = loadPassphrase() != nil
        let cryptoStoreExists = matrixCryptoStoreExists(in: sharedData.url)
        let ready = sharedData.hasContents && sharedCache.hasContents && cryptoStoreExists && session != nil && passphrasePresent

        var out = "NSE readiness\n"
        out += "ready=\(ready ? "YES" : "NO")\n"
        out += "shared.lastUserId=\(sharedLastUserId() ?? "<nil>")\n"
        out += "session=\(session.map { "\($0.userId) device=\($0.deviceId)" } ?? "<nil>")\n"
        out += "passphrasePresent=\(passphrasePresent)\n"
        out += "sharedDataHasContents=\(sharedData.hasContents)\n"
        out += "sharedCacheHasContents=\(sharedCache.hasContents)\n"
        out += "sharedCryptoDbExists=\(cryptoStoreExists)\n"
        out += "verdict=\(ready ? "NSE can attempt restore" : "NSE should skip Matrix restore")"
        return out
    }

    static func inspectKeychainSession() -> String {
        var out = "Keychain session\n"
        out += "session service=\(sessionService)\n"
        out += "selected=\(selectedStoredSession().map { "\($0.label): \($0.session.userId) device=\($0.session.deviceId)" } ?? "<nil>")\n"

        for (label, kc) in sessionKeychains() {
            let keys = kc.allKeys().sorted()
            out += "\n[\(label)] userIds: \(keys.isEmpty ? "<none>" : keys.joined(separator: ", "))\n"
            for key in keys {
                if let session = decodeSession(from: kc, key: key) {
                    out += "  - \(session.userId)\n"
                    out += "    deviceId=\(session.deviceId)\n"
                    out += "    homeserver=\(session.homeserverUrl)\n"
                    out += "    hasAccessToken=\(!session.accessToken.isEmpty) hasRefreshToken=\(session.refreshToken?.isEmpty == false)\n"
                } else {
                    out += "  - \(key) <decode failed>\n"
                }
            }
        }

        out += "\npassphrase present=\(loadPassphrase() != nil)\n"
        return out
    }

    static func inspectUserDefaults() -> String {
        var out = "UserDefaults markers\n"
        out += "shared.lastUserId=\(sharedLastUserId() ?? "<nil>")\n\n"
        out += "standard defaults (com.zyna.*):\n"
        let dict = UserDefaults.standard.dictionaryRepresentation()
        let keys = dict.keys.filter { $0.hasPrefix("com.zyna") }.sorted()
        if keys.isEmpty { out += "  <none>\n" }
        for key in keys {
            if key == cryptoIdentityFingerprintKey {
                out += "  \(key) = \(storedFingerprintSummary())\n"
            } else {
                out += "  \(key) = \(dict[key].map { "\($0)" } ?? "nil")\n"
            }
        }
        return out
    }

    static func fingerprintReport() -> String {
        var out = "Crypto identity fingerprint\n"
        guard let stored = storedCryptoIdentityFingerprint() else {
            out += "stored=<nil>\n"
            out += "meaning=no baseline saved yet; a good app login/restore will create it."
            return out
        }

        out += "stored.userId=\(stored.userId)\n"
        out += "stored.deviceId=\(stored.deviceId)\n"
        out += "stored.curve25519=\(stored.curve25519Key)\n"
        out += "stored.ed25519=\(stored.ed25519Key)"
        return out
    }

    static func localIdentityReadWouldOpenStore() -> Bool {
        sharedMatrixCryptoStoreExists()
    }

    // MARK: - Network / store-opening checks

    static func compareStoredFingerprintWithServer() async -> String {
        guard let stored = storedCryptoIdentityFingerprint() else {
            return "Stored fingerprint is missing. Nothing to compare without opening the crypto store."
        }
        guard let (_, session) = storedSession(userId: stored.userId) ?? selectedStoredSession(),
              session.userId == stored.userId,
              session.deviceId == stored.deviceId else {
            return "No matching keychain session for stored fingerprint userId=\(stored.userId) deviceId=\(stored.deviceId)."
        }

        do {
            let server = try await fetchServerDeviceKeys(session: session)
            return renderIdentityComparison(
                title: "Stored fingerprint vs homeserver /keys/query",
                userId: stored.userId,
                deviceId: stored.deviceId,
                localCurve: stored.curve25519Key,
                localEd: stored.ed25519Key,
                serverDevice: server
            )
        } catch {
            return "Stored fingerprint vs homeserver failed: \(error)"
        }
    }

    static func compareLocalIdentityWithServer() async -> String {
        guard let (_, session) = selectedStoredSession() else {
            return "No session in keychain - nothing to restore."
        }

        guard sharedMatrixCryptoStoreExists() else {
            return """
            Refusing to open Matrix SDK store because shared \(matrixCryptoStoreDatabaseName) is missing.

            This is the state the restore guard is meant to block. Opening the SDK here could create a new local Olm identity under the saved deviceId.
            """
        }

        do {
            let local = try await readLocalIdentityOpeningStore(session: session)
            let server = try await fetchServerDeviceKeys(session: session)
            return renderIdentityComparison(
                title: "Local SDK identity vs homeserver /keys/query",
                userId: session.userId,
                deviceId: session.deviceId,
                localCurve: local.curve25519,
                localEd: local.ed25519,
                serverDevice: server
            ) + "\n\nStore was opened by the diagnostics client. Restart before destructive operations."
        } catch {
            return "Local vs server comparison failed: \(error)"
        }
    }

    /// Opens the local crypto store only if the shared crypto DB already exists.
    static func readIdentity() async -> String {
        guard let (_, session) = selectedStoredSession() else {
            return "No session in keychain - nothing to restore."
        }

        guard sharedMatrixCryptoStoreExists() else {
            return """
            Refusing to open Matrix SDK store because shared \(matrixCryptoStoreDatabaseName) is missing.

            Expected post-fix app behavior: clear the saved session and show logged-out state, not resurrect the saved deviceId on a new crypto identity.
            """
        }

        do {
            let local = try await readLocalIdentityOpeningStore(session: session)
            return """
            userId        = \(session.userId)
            deviceId      = \(session.deviceId)
            curve25519    = \(local.curve25519)
            ed25519       = \(local.ed25519)
            verification  = \(local.verification)
            recovery      = \(local.recovery)

            Store was opened by the diagnostics client. Restart before destructive operations.
            """
        } catch {
            return "identity read failed: \(error)"
        }
    }

    // MARK: - Destructive actions

    static func preparePostFixMissingCryptoStoreTest() -> String {
        var out = removeStoreDirectories()
        out += "keychain (session + passphrase) left intact.\n"
        out += "expected next normal app launch: restore guard BLOCKS, clears saved session, and shows logged-out state.\n"
        out += "unexpected/regression: same deviceId restores with new curve25519/ed25519 keys.\n"
        return out
    }

    static func wipeCryptoStoreKeepKeychain() -> String {
        var out = removeStoreDirectories()
        out += "keychain (session + passphrase) left intact.\n"
        out += "expected next normal app launch: restore guard blocks and clears the saved session."
        return out
    }

    static func wipeKeychainSessionKeepStore() -> String {
        var out = "clearing session keychain, keeping Matrix store...\n"
        for (_, kc) in sessionKeychains() {
            do { try kc.removeAll() } catch { out += "  removeAll failed: \(error)\n" }
        }
        out += "expected next launch: no saved session -> fresh login."
        return out
    }

    static func corruptCryptoDb() -> String {
        let dbs = matrixDataDirectorySnapshots(for: selectedStoredSession()?.session.userId)
            .map { $0.url.appendingPathComponent(matrixCryptoStoreDatabaseName, isDirectory: false) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !dbs.isEmpty else {
            return "No \(matrixCryptoStoreDatabaseName) found in known data store candidates."
        }

        var out = ""
        let garbage = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        for db in uniqueURLs(dbs) {
            if let handle = try? FileHandle(forWritingTo: db) {
                try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: garbage)
                try? handle.close()
                out += "corrupted header: \(db.path)\n"
            } else {
                out += "cannot open: \(db.path)\n"
            }
        }
        out += "expected next launch: SDK restore fails or restore guard blocks before a new identity is created."
        return out
    }

    static func wipeEverything() -> String {
        var out = removeStoreDirectories()
        for kc in [
            ZynaSecurityConfig.sharedKeychain(service: sessionService),
            ZynaSecurityConfig.legacyKeychain(service: sessionService),
            ZynaSecurityConfig.sharedKeychain(service: passphraseService),
            ZynaSecurityConfig.legacyKeychain(service: passphraseService)
        ] {
            try? kc.removeAll()
        }
        ZynaSecurityConfig.clearSharedLastMatrixUserId()
        let dict = UserDefaults.standard.dictionaryRepresentation()
        for key in dict.keys where key.hasPrefix("com.zyna") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
        out += "cleared session + passphrase keychain, shared lastUserId, com.zyna.* defaults.\n"
        out += "expected next launch: clean slate -> brand new login."
        return out
    }

    // MARK: - Local SDK restore

    private static func readLocalIdentityOpeningStore(
        session: StoredSessionData
    ) async throws -> (curve25519: String, ed25519: String, verification: Any, recovery: Any) {
        guard let passphrase = loadPassphrase() else {
            throw DiagnosticsError("No store passphrase in keychain.")
        }
        guard let dataPath = LocalDataProtection.sharedMatrixDataDirectory()?.path,
              let cachePath = LocalDataProtection.sharedMatrixCacheDirectory()?.path else {
            throw DiagnosticsError("App Group store paths unavailable.")
        }

        let storeConfig = SqliteStoreBuilder(dataPath: dataPath, cachePath: cachePath)
            .passphrase(passphrase: passphrase)
        let sessionDelegate = DiagnosticsSessionDelegate()
        let client = try await ClientBuilder()
            .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: lockHolder))
            .setSessionDelegate(sessionDelegate: sessionDelegate)
            .homeserverUrl(url: session.homeserverUrl)
            .sqliteStore(config: storeConfig)
            .build()

        let sdkSession = MatrixRustSDK.Session(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oauthData: session.oauthData,
            slidingSyncVersion: .native
        )
        try await client.restoreSession(session: sdkSession)

        let encryption = client.encryption()
        return (
            await encryption.curve25519Key() ?? "nil",
            await encryption.ed25519Key() ?? "nil",
            encryption.verificationState(),
            encryption.recoveryState()
        )
    }

    // MARK: - Server device keys

    private static func fetchServerDeviceKeys(session: StoredSessionData) async throws -> ServerDeviceKeys? {
        let url = try makeClientURL(
            homeserverUrl: session.homeserverUrl,
            path: "/_matrix/client/v3/keys/query"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ServerKeysQueryRequest(
                deviceKeys: [session.userId: [session.deviceId]],
                timeout: 10_000
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DiagnosticsError("Invalid /keys/query response.")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw DiagnosticsError("/keys/query HTTP \(http.statusCode): \(body)")
        }

        let decoded = try JSONDecoder().decode(ServerKeysQueryResponse.self, from: data)
        return decoded.deviceKeys[session.userId]?[session.deviceId]
    }

    private static func renderIdentityComparison(
        title: String,
        userId: String,
        deviceId: String,
        localCurve: String,
        localEd: String,
        serverDevice: ServerDeviceKeys?
    ) -> String {
        var out = "\(title)\n"
        out += "userId=\(userId)\n"
        out += "deviceId=\(deviceId)\n"
        out += "local.curve25519=\(localCurve)\n"
        out += "local.ed25519=\(localEd)\n"

        guard let serverDevice else {
            out += "server=<device not returned by /keys/query>\n"
            out += "verdict=MISMATCH"
            return out
        }

        let server = serverDevice.identityKeys(for: deviceId)
        out += "server.curve25519=\(server.curve25519 ?? "nil")\n"
        out += "server.ed25519=\(server.ed25519 ?? "nil")\n"
        let matches = localCurve == server.curve25519 && localEd == server.ed25519
        out += "verdict=\(matches ? "MATCH" : "MISMATCH")"
        return out
    }

    // MARK: - Path helpers

    private static func matrixDataDirectorySnapshots(for userId: String?) -> [DirectorySnapshot] {
        [
            directorySnapshot(label: "shared data", url: LocalDataProtection.sharedMatrixDataDirectory()),
            directorySnapshot(label: "legacy data", url: legacyMatrixDataDirectory()),
            directorySnapshot(label: "local no-session data", url: LocalDataProtection.matrixDataDirectory(for: nil)),
            userId.map { directorySnapshot(label: "local user data", url: LocalDataProtection.matrixDataDirectory(for: $0)) }
        ]
        .compactMap { $0 }
        .uniquedByPath()
    }

    private static func matrixCacheDirectorySnapshots(for userId: String?) -> [DirectorySnapshot] {
        [
            directorySnapshot(label: "shared cache", url: LocalDataProtection.sharedMatrixCacheDirectory()),
            directorySnapshot(label: "legacy cache", url: legacyMatrixCacheDirectory()),
            directorySnapshot(label: "local no-session cache", url: LocalDataProtection.matrixCacheDirectory(for: nil)),
            userId.map { directorySnapshot(label: "local user cache", url: LocalDataProtection.matrixCacheDirectory(for: $0)) }
        ]
        .compactMap { $0 }
        .uniquedByPath()
    }

    private static func directorySnapshot(label: String, url: URL?) -> DirectorySnapshot {
        guard let url else {
            return DirectorySnapshot(label: label, url: URL(fileURLWithPath: "<nil>"), exists: false, isDirectory: false, entries: [])
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue,
              let items = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: []
              ) else {
            return DirectorySnapshot(label: label, url: url, exists: exists, isDirectory: isDirectory.boolValue, entries: [])
        }

        let entries = items.map { item -> DirectoryEntry in
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            return DirectoryEntry(
                name: item.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize ?? 0,
                modified: values?.contentModificationDate
            )
        }
        .sorted { $0.name < $1.name }

        return DirectorySnapshot(label: label, url: url, exists: exists, isDirectory: true, entries: entries)
    }

    private static func renderDirectorySummary(_ snapshot: DirectorySnapshot) -> String {
        let crypto = snapshot.file(named: matrixCryptoStoreDatabaseName)
        let state = snapshot.file(named: matrixStateStoreDatabaseName)
        let wal = snapshot.file(named: "\(matrixCryptoStoreDatabaseName)-wal")
        let shm = snapshot.file(named: "\(matrixCryptoStoreDatabaseName)-shm")
        return """
        - \(snapshot.label): exists=\(snapshot.exists) contents=\(snapshot.entries.count) crypto=\(fileSummary(crypto)) cryptoWal=\(fileSummary(wal)) cryptoShm=\(fileSummary(shm)) state=\(fileSummary(state))
          path=\(snapshot.url.path)
        """
    }

    private static func fileSummary(_ entry: DirectoryEntry?) -> String {
        guard let entry else { return "missing" }
        var out = byteString(entry.size)
        if let modified = entry.modified {
            out += "@\(dateString(modified))"
        }
        return out
    }

    private static func matrixCryptoStoreExists(in directory: URL) -> Bool {
        let databaseURL = directory.appendingPathComponent(matrixCryptoStoreDatabaseName, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: databaseURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let resourceValues = try? databaseURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = resourceValues.fileSize else {
            return false
        }

        return fileSize > 0
    }

    private static func sharedMatrixCryptoStoreExists() -> Bool {
        guard let dataDirectory = LocalDataProtection.sharedMatrixDataDirectory() else { return false }
        return matrixCryptoStoreExists(in: dataDirectory)
    }

    private static func removeStoreDirectories() -> String {
        let fm = FileManager.default
        let userId = selectedStoredSession()?.session.userId
        let directories = uniqueURLs(
            matrixDataDirectorySnapshots(for: userId).map(\.url) +
            matrixCacheDirectorySnapshots(for: userId).map(\.url)
        )

        var out = "removing Matrix store directories...\n"
        for dir in directories {
            if fm.fileExists(atPath: dir.path) {
                do {
                    try fm.removeItem(at: dir)
                    out += "removed \(dir.path)\n"
                } catch {
                    out += "FAILED \(dir.path): \(error)\n"
                }
            } else {
                out += "absent \(dir.path)\n"
            }
        }
        return out
    }

    private static func legacyMatrixDataDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
    }

    private static func legacyMatrixCacheDirectory() -> URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
    }

    // MARK: - Session / defaults helpers

    private static func selectedStoredSession() -> (label: String, session: StoredSessionData)? {
        if let userId = sharedLastUserId(), let result = storedSession(userId: userId) {
            return result
        }
        return firstStoredSession()
    }

    private static func storedSession(userId: String) -> (String, StoredSessionData)? {
        for (label, kc) in sessionKeychains() {
            if let session = decodeSession(from: kc, key: userId) {
                return (label, session)
            }
        }
        return nil
    }

    private static func firstStoredSession() -> (String, StoredSessionData)? {
        for (label, kc) in sessionKeychains() {
            if let userId = kc.allKeys().sorted().first,
               let session = decodeSession(from: kc, key: userId) {
                return (label, session)
            }
        }
        return nil
    }

    private static func sessionKeychains() -> [(String, Keychain)] {
        [
            ("shared", ZynaSecurityConfig.sharedKeychain(service: sessionService)),
            ("legacy", ZynaSecurityConfig.legacyKeychain(service: sessionService))
        ]
    }

    private static func decodeSession(from keychain: Keychain, key: String) -> StoredSessionData? {
        let json: String?
        do {
            json = try keychain.get(key)
        } catch {
            return nil
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredSessionData.self, from: data)
    }

    private static func loadPassphrase() -> String? {
        if let value = try? ZynaSecurityConfig.sharedKeychain(service: passphraseService).get(passphraseKey) {
            return value
        }
        if let value = try? ZynaSecurityConfig.legacyKeychain(service: passphraseService).get(passphraseKey) {
            return value
        }
        return nil
    }

    private static func sharedLastUserId() -> String? {
        UserDefaults(suiteName: appGroupIdentifier)?.string(forKey: matrixLastUserIdKey)
    }

    private static func storedCryptoIdentityFingerprint() -> LocalCryptoIdentityFingerprint? {
        guard let data = UserDefaults.standard.data(forKey: cryptoIdentityFingerprintKey) else {
            return nil
        }
        return try? JSONDecoder().decode(LocalCryptoIdentityFingerprint.self, from: data)
    }

    private static func storedFingerprintSummary() -> String {
        guard let fingerprint = storedCryptoIdentityFingerprint() else {
            return "<decode failed or nil>"
        }
        return "userId=\(fingerprint.userId) deviceId=\(fingerprint.deviceId) curve25519=\(fingerprint.curve25519Key) ed25519=\(fingerprint.ed25519Key)"
    }

    // MARK: - Generic helpers

    private static func reportHeader() -> String {
        """
        Zyna Crypto Diagnostics
        generated=\(dateString(Date()))
        appGroup=\(appGroupIdentifier)
        privacy=no tokens included; report can still contain user IDs, device IDs, room/event/session IDs, server names, and local file paths.
        diagnosticsEnabled=\(CryptoDiagnosticsGate.isEnabled)
        rustTracingStdout=\(CryptoDiagnosticsGate.isTruthyEnvironmentValue("ZYNA_RUST_TRACING_STDOUT"))
        """
    }

    private static func makeClientURL(homeserverUrl: String, path: String) throws -> URL {
        var raw = homeserverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              components.host != nil,
              scheme == "http" || scheme == "https" else {
            throw DiagnosticsError("Invalid homeserver URL: \(homeserverUrl)")
        }

        components.path = path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw DiagnosticsError("Invalid homeserver URL: \(homeserverUrl)")
        }
        return url
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(url)
        }
        return result
    }

    private static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func dateString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct DiagnosticsError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private extension Array where Element == CryptoDiagnosticsService.DirectorySnapshot {
    func uniquedByPath() -> [CryptoDiagnosticsService.DirectorySnapshot] {
        var seen = Set<String>()
        var result: [CryptoDiagnosticsService.DirectorySnapshot] = []
        for snapshot in self {
            let path = snapshot.url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(snapshot)
        }
        return result
    }
}

/// Minimal session delegate so the diagnostics client can be built with a
/// multi-process cross-process lock (the SDK requires one). Reads the same
/// shared session keychain the app and NSE use; saves are intentionally ignored.
private final class DiagnosticsSessionDelegate: ClientSessionDelegate, @unchecked Sendable {
    private struct Stored: Codable {
        let accessToken: String
        let refreshToken: String?
        let userId: String
        let deviceId: String
        let homeserverUrl: String
        let oauthData: String?
    }

    private let service = "com.zyna.matrix.session"

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        for keychain in [
            ZynaSecurityConfig.sharedKeychain(service: service),
            ZynaSecurityConfig.legacyKeychain(service: service)
        ] {
            if let json = try? keychain.get(userId),
               let data = json.data(using: .utf8),
               let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                return Session(
                    accessToken: stored.accessToken,
                    refreshToken: stored.refreshToken,
                    userId: stored.userId,
                    deviceId: stored.deviceId,
                    homeserverUrl: stored.homeserverUrl,
                    oauthData: stored.oauthData,
                    slidingSyncVersion: .native
                )
            }
        }
        throw ClientError.Generic(msg: "Diagnostics: no session for \(userId)", details: nil)
    }

    func saveSessionInKeychain(session: Session) {}
}
#endif
