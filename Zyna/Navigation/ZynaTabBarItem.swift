//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Single tab descriptor for `ZynaTabBarController`. Replaces
/// `UITabBarItem` so we can extend it with our own affordances
/// (badge styles, accent overrides, etc.) without fighting UIKit.
public struct ZynaTabBarItem: Equatable {

    public let title: String

    /// Rendered when the tab is not selected. Should be a template
    /// image so the tab bar can recolor it via `tintColor`.
    public let icon: UIImage?

    /// Optional alternate image for the selected state. If nil, the
    /// regular `icon` is reused with the accent tint applied.
    public let selectedIcon: UIImage?

    /// Badge value displayed in the upper-right of the icon.
    /// `nil` hides the badge entirely. Empty string shows a dot.
    public var badge: String?

    public init(
        title: String,
        icon: UIImage?,
        selectedIcon: UIImage? = nil,
        badge: String? = nil
    ) {
        self.title = title
        self.icon = icon?.withRenderingMode(.alwaysTemplate)
        self.selectedIcon = selectedIcon?.withRenderingMode(.alwaysTemplate)
        self.badge = badge
    }
}
