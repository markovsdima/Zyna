//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum ContextMenuActionBehavior {
    case dismissBeforeHandling
    case handleInMenu
}

struct ContextMenuAction {
    let title: String
    let image: UIImage?
    let isDestructive: Bool
    let behavior: ContextMenuActionBehavior
    let handler: () -> Void

    init(
        title: String,
        image: UIImage?,
        isDestructive: Bool = false,
        behavior: ContextMenuActionBehavior = .dismissBeforeHandling,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.image = image
        self.isDestructive = isDestructive
        self.behavior = behavior
        self.handler = handler
    }
}
