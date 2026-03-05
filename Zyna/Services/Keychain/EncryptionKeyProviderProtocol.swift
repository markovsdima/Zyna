//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

protocol EncryptionKeyProviderProtocol {
    func generateKey() -> Data
}
