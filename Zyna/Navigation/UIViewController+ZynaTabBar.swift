//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

public extension UIViewController {

    /// Enclosing `ZynaTabBarController`, walking the parent chain.
    /// Returns nil if not embedded in one. UIKit's `tabBarController`
    /// only finds `UITabBarController` subclasses.
    var zynaTabBarController: ZynaTabBarController? {
        sequence(first: self, next: { $0.parent })
            .first(where: { $0 is ZynaTabBarController })
            as? ZynaTabBarController
    }
}
