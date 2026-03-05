//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation

struct EncryptionKeyProvider: EncryptionKeyProviderProtocol {
    func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
            Data(Array(bytes))
        }
    }
}
