//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

extension MediaSource {

    /// Ruma serializes an encrypted source as `{"file": {...}}` and a plain
    /// one as `{"url": "mxc://..."}`. `url()` is the same for both, so this is
    /// the only way to tell them apart across the FFI. One FFI call plus a
    /// JSON parse: resolve it once when mapping an item, never in a view.
    var isEncryptedSource: Bool {
        guard let data = toJson().data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["file"] != nil
    }
}
