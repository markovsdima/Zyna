//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import ObjectiveC

public extension UIView {

    /// Set to `true` to opt out of the navigation interactive-pop
    /// gesture in this view's hit-test region — image carousels,
    /// chip strips, paging collection views, anything else that
    /// needs to claim horizontal pan input.
    ///
    /// `InteractiveTransitionGestureRecognizer` already auto-detects
    /// `UIScrollView`s whose content is wider than their bounds, so
    /// this flag is only needed for non-scroll-view widgets or to
    /// make the intent explicit at the call site.
    var disablesInteractiveTransitionGestureRecognizer: Bool {
        get {
            objc_getAssociatedObject(
                self, &AssociatedKeys.disableInteractiveTransition
            ) as? Bool ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &AssociatedKeys.disableInteractiveTransition,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

private enum AssociatedKeys {
    static var disableInteractiveTransition: UInt8 = 0
}
