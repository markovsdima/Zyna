//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

struct ContextMenuAction {
    let title: String
    let image: UIImage?
    let isDestructive: Bool
    let handler: () -> Void

    init(
        title: String,
        image: UIImage?,
        isDestructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.image = image
        self.isDestructive = isDestructive
        self.handler = handler
    }
}
