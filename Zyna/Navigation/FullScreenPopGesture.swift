//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import ObjectiveC

private var popGestureDelegateKey: UInt8 = 0
private var popGestureInstalledKey: UInt8 = 0

extension UINavigationController {

    /// Enables full-screen interactive pop gesture (swipe back from anywhere).
    /// Call after the navigation controller's view is in the hierarchy
    /// (e.g. after the first push).
    func enableFullScreenPopGesture() {
        guard objc_getAssociatedObject(self, &popGestureInstalledKey) == nil else { return }
        guard let target = interactivePopGestureRecognizer?.delegate else {
            print("[pop-gesture] interactivePopGestureRecognizer delegate is nil")
            return
        }

        let selector = NSSelectorFromString(
            ["handle", "Navigation", "Transition:"].joined()
        )
        guard target.responds(to: selector) else {
            print("[pop-gesture] target does not respond to selector")
            return
        }

        objc_setAssociatedObject(self, &popGestureInstalledKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let gestureDelegate = PopGestureDelegate(navigationController: self)
        objc_setAssociatedObject(self, &popGestureDelegateKey, gestureDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let pan = UIPanGestureRecognizer(target: target, action: selector)
        pan.delegate = gestureDelegate
        view.addGestureRecognizer(pan)

        interactivePopGestureRecognizer?.isEnabled = false
        print("[pop-gesture] installed successfully")
    }
}

private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {

    private weak var navigationController: UINavigationController?

    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController,
              nav.viewControllers.count > 1,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return false
        }
        let translation = pan.translation(in: pan.view)
        return translation.x > 0 && abs(translation.x) > abs(translation.y)
    }
}
