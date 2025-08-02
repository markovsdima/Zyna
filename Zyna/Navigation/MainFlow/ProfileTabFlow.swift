//
//  ProfileTabFlow.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 04.07.2025.
//

import RxFlow
import AsyncDisplayKit

enum ProfileStep: Step {
    case profile
}

class ProfileFlow: Flow {
    var root: Presentable { return rootNavController }
    private let rootNavController = ASDKNavigationController()
    
    func navigate(to step: Step) -> FlowContributors {
        guard let step = step as? ProfileStep else { return .none }
        
        switch step {
        case .profile:
            let vc = ProfileViewController()
            rootNavController.setViewControllers([vc], animated: false)
            return .one(flowContributor: .contribute(
                withNextPresentable: vc,
                withNextStepper: vc
            ))
        }
    }
}
