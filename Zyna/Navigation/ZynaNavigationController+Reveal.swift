// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

extension ZynaNavigationController {
    /// Selects this stack only when no modal screen would be displaced.
    /// The caller keeps its action available if routing cannot proceed.
    func revealForRouting() -> Bool {
        var root: UIViewController = self
        while let parent = root.parent { root = parent }
        guard Self.modalPresenter(in: root) == nil else { return false }
        if let tabs = zynaTabBarController {
            let tab = sequence(first: self as UIViewController, next: { $0.parent })
                .first { $0.parent === tabs }
            guard let index = tabs.controllers.firstIndex(where: { $0 === tab }) else { return false }
            // The destination's push supplies the animation. Switching the
            // tab synchronously also avoids routing into a hidden stack.
            tabs.setSelectedIndex(index, animated: false, completion: nil)
        }
        return true
    }

    private static func modalPresenter(in controller: UIViewController) -> UIViewController? {
        if controller.presentedViewController != nil { return controller }
        // A presentation can belong to a child that defines its own context.
        let visibleChild: UIViewController?
        if let tabs = controller as? ZynaTabBarController { visibleChild = tabs.selectedController }
        else if let navigation = controller as? ZynaNavigationController { visibleChild = navigation.topViewController }
        else if let navigation = controller as? UINavigationController { visibleChild = navigation.visibleViewController }
        else { visibleChild = controller.children.first { $0.viewIfLoaded?.window != nil } }
        return visibleChild.flatMap { modalPresenter(in: $0) }
    }
}
