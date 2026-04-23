//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

public extension UIViewController {

    /// Enclosing `ZynaNavigationController`, walking the parent
    /// chain. Returns nil if not embedded in one. UIKit's
    /// `navigationController` property doesn't work for us — it
    /// only finds `UINavigationController` subclasses.
    var zynaNavigationController: ZynaNavigationController? {
        sequence(first: self, next: { $0.parent })
            .first(where: { $0 is ZynaNavigationController })
            as? ZynaNavigationController
    }
}
