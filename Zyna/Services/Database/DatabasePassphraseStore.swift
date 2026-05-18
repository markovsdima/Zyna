//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import KeychainAccess
import Security

enum DatabasePassphraseStore {

    private static let keychain = Keychain(service: "com.zyna.localdata.database")
        .accessibility(.afterFirstUnlockThisDeviceOnly)

    static func passphraseData(for userId: String?) throws -> Data {
        let key = keychainKey(for: userId)
        if let existing = try keychain.getData(key), existing.count >= 32 {
            return existing
        }

        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw DatabasePassphraseError.randomGenerationFailed(status)
        }

        try keychain.set(data, key: key)
        return data
    }

    static func removePassphrase(for userId: String?) {
        try? keychain.remove(keychainKey(for: userId))
    }

    static func removeAllPassphrases() {
        try? keychain.removeAll()
    }

    private static func keychainKey(for userId: String?) -> String {
        "db-key-\(LocalDataProtection.userScope(for: userId))"
    }
}

enum DatabasePassphraseError: Error {
    case randomGenerationFailed(OSStatus)
}

enum DatabaseEncryptionError: Error {
    case sqlCipherUnavailable
}
