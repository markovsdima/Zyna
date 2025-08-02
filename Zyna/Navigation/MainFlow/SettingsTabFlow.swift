//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import RxFlow
import AsyncDisplayKit

enum SettingsStep: Step {
    case settings
}

class SettingsFlow: Flow {
    var root: Presentable { return rootNavController }
    private let rootNavController = ASDKNavigationController()
    
    func navigate(to step: Step) -> FlowContributors {
        guard let step = step as? SettingsStep else { return .none }
        
        switch step {
        case .settings:
            let vc = SettingsViewController()
            rootNavController.setViewControllers([vc], animated: false)
            return .one(flowContributor: .contribute(
                withNextPresentable: vc,
                withNextStepper: vc
            ))
        }
    }
}
