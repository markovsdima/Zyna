//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
@preconcurrency import KeychainAccess

enum ZynaSecurityConfig {
    static let appGroupIdentifier = "group.com.app.zyna"
    static let keychainAccessGroup = "UM3QPHF8E3.com.app.zyna.shared"

    static func sharedKeychain(service: String) -> Keychain {
        Keychain(service: service, accessGroup: keychainAccessGroup)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    static func legacyKeychain(service: String) -> Keychain {
        Keychain(service: service)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

}
