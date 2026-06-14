//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
@preconcurrency import KeychainAccess

enum ZynaSecurityConfig {
    static let appGroupIdentifier = "group.com.app.zyna"
    static let matrixLastUserIdKey = "com.zyna.matrix.lastUserId"
    private static let keychainAccessGroupInfoPlistKey = "ZynaKeychainAccessGroup"
    private static let fallbackKeychainAccessGroup = "UM3QPHF8E3.com.app.zyna.shared"

    static let keychainAccessGroup: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: keychainAccessGroupInfoPlistKey) as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return fallbackKeychainAccessGroup
        }
        return value
    }()

    static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func sharedUserDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func setSharedLastMatrixUserId(_ userId: String) {
        let defaults = sharedUserDefaults()
        defaults?.set(userId, forKey: matrixLastUserIdKey)
        defaults?.synchronize()
    }

    static func clearSharedLastMatrixUserId() {
        let defaults = sharedUserDefaults()
        defaults?.removeObject(forKey: matrixLastUserIdKey)
        defaults?.synchronize()
    }

    static func sharedKeychain(service: String) -> Keychain {
        Keychain(service: service, accessGroup: keychainAccessGroup)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    static func legacyKeychain(service: String) -> Keychain {
        Keychain(service: service)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

}
