// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit
import UniformTypeIdentifiers

extension UIPasteboard {
    @MainActor func writeLink(_ url: URL) {
        setItems([[UTType.url.identifier: url,
                   UTType.utf8PlainText.identifier: url.absoluteString]], options: [:])
    }
}
