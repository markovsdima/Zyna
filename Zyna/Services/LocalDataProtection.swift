//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation

enum LocalDataProtection {

    enum ProtectionClass {
        case sensitive
        case backgroundReadable

        var fileProtection: FileProtectionType {
            switch self {
            case .sensitive:
                return .completeUnlessOpen
            case .backgroundReadable:
                return .completeUntilFirstUserAuthentication
            }
        }
    }

    private static let appDirectoryName = "zyna"
    private static let usersDirectoryName = "users"
    private static let noSessionScope = "no-session"
    private static let temporaryFilePrefixes = [
        "zyna-forward-",
        "zyna-image-",
        "zyna-picked-",
        "zyna-video-"
    ]

    static func appSupportRoot() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    static func cachesRoot() -> URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    static func userScope(for userId: String?) -> String {
        guard let userId, !userId.isEmpty else {
            return noSessionScope
        }
        let digest = SHA256.hash(data: Data(userId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func userSupportDirectory(for userId: String?) -> URL {
        appSupportRoot()
            .appendingPathComponent(usersDirectoryName, isDirectory: true)
            .appendingPathComponent(userScope(for: userId), isDirectory: true)
    }

    static func userCachesDirectory(for userId: String?) -> URL {
        cachesRoot()
            .appendingPathComponent(usersDirectoryName, isDirectory: true)
            .appendingPathComponent(userScope(for: userId), isDirectory: true)
    }

    static func databaseURL(for userId: String?) -> URL {
        userSupportDirectory(for: userId).appendingPathComponent("zyna.db")
    }

    static func mediaCacheDirectory(for userId: String?) -> URL {
        userSupportDirectory(for: userId)
            .appendingPathComponent("media-cache", isDirectory: true)
    }

    static func outgoingVoiceDirectory(for userId: String?) -> URL {
        userSupportDirectory(for: userId)
            .appendingPathComponent("outgoing-voice", isDirectory: true)
    }

    static func outgoingImageDirectory(for userId: String?) -> URL {
        userSupportDirectory(for: userId)
            .appendingPathComponent("outgoing-image", isDirectory: true)
    }

    static func voiceRecordingDirectory(for userId: String?) -> URL {
        userSupportDirectory(for: userId)
            .appendingPathComponent("voice-recordings-temp", isDirectory: true)
    }

    static func thumbnailsDirectory(for userId: String?) -> URL {
        userCachesDirectory(for: userId)
            .appendingPathComponent("thumbnails", isDirectory: true)
    }

    static func matrixDataDirectory(for userId: String?) -> URL {
        appSupportRoot()
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent(userScope(for: userId), isDirectory: true)
    }

    static func matrixCacheDirectory(for userId: String?) -> URL {
        cachesRoot()
            .appendingPathComponent("matrix", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(userScope(for: userId), isDirectory: true)
    }

    @discardableResult
    static func createProtectedDirectory(
        at url: URL,
        protection: ProtectionClass,
        excludeFromBackup: Bool
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: protection.fileProtection]
        )
        try applyProtection(to: url, protection: protection)

        if excludeFromBackup {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
        }

        return url
    }

    static func applyProtection(to url: URL, protection: ProtectionClass) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: protection.fileProtection],
            ofItemAtPath: url.path
        )
    }

    static func writeProtectedData(
        _ data: Data,
        to url: URL,
        protection: ProtectionClass
    ) throws {
        try createProtectedDirectory(
            at: url.deletingLastPathComponent(),
            protection: protection,
            excludeFromBackup: true
        )
        try data.write(to: url, options: .atomic)
        try applyProtection(to: url, protection: protection)
    }

    static func protectExistingDatabaseFiles(for userId: String?) {
        let dbURL = databaseURL(for: userId)
        for url in sqliteSidecarURLs(for: dbURL) {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? applyProtection(to: url, protection: .sensitive)
        }
    }

    static func removeAppDatabase(for userId: String?) {
        let fm = FileManager.default
        for url in sqliteSidecarURLs(for: databaseURL(for: userId)) {
            try? fm.removeItem(at: url)
        }
    }

    static func removeUserLocalData(userId: String?) {
        let fm = FileManager.default
        let supportDirectory = userSupportDirectory(for: userId)
        let cachesDirectory = userCachesDirectory(for: userId)

        removeAppDatabase(for: userId)
        try? fm.removeItem(at: supportDirectory)
        try? fm.removeItem(at: cachesDirectory)
    }

    static func removeAllUserLocalData() {
        let fm = FileManager.default
        try? fm.removeItem(at: appSupportRoot().appendingPathComponent(usersDirectoryName, isDirectory: true))
        try? fm.removeItem(at: cachesRoot().appendingPathComponent(usersDirectoryName, isDirectory: true))
    }

    static func removeMatrixNoSessionStore() {
        let fm = FileManager.default
        try? fm.removeItem(at: matrixDataDirectory(for: nil))
        try? fm.removeItem(at: matrixCacheDirectory(for: nil))
    }

    static func removeTemporaryLocalData() {
        let fm = FileManager.default
        let temporaryDirectory = fm.temporaryDirectory
        guard let urls = try? fm.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in urls where temporaryFilePrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            try? fm.removeItem(at: url)
        }
    }

    static func removeLegacyGlobalLocalData() {
        let fm = FileManager.default
        let appSupport = appSupportRoot()
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!

        let legacyURLs = [
            appSupport.appendingPathComponent("zyna.db"),
            appSupport.appendingPathComponent("zyna.db-wal"),
            appSupport.appendingPathComponent("zyna.db-shm"),
            appSupport.appendingPathComponent("zyna.db-journal"),
            appSupport.appendingPathComponent("media-cache", isDirectory: true),
            appSupport.appendingPathComponent("outgoing-voice", isDirectory: true),
            appSupport.appendingPathComponent("document-scanning", isDirectory: true),
            caches.appendingPathComponent("zyna-thumbnails", isDirectory: true),
            caches.appendingPathComponent("zyna/document-scanning", isDirectory: true)
        ]

        for url in legacyURLs {
            try? fm.removeItem(at: url)
        }
    }

    private static func sqliteSidecarURLs(for dbURL: URL) -> [URL] {
        [
            dbURL,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm"),
            URL(fileURLWithPath: dbURL.path + "-journal")
        ]
    }
}
