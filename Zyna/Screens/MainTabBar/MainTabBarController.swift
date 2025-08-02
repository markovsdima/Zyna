//
//  MainTabBarController.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 04.07.2025.
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
