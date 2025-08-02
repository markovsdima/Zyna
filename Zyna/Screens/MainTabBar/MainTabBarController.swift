//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import RxFlow

class MainTabBarController: ASTabBarController, UITabBarControllerDelegate {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.delegate = self
    }
    
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let fromView = selectedViewController?.view,
              let toView = viewController.view
        else { return false }
        
        if fromView != toView {
            UIView.transition(from: fromView, to: toView, duration: 0, options: [.transitionCrossDissolve], completion: nil)
        }
        return true
    }
}
