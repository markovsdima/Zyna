//
//  AppFlow.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 29.04.2025.
//

import RxFlow
import AsyncDisplayKit

enum AppStep: Step {
    case authFlow
    case mainFlow
}

class AppFlow: Flow {
    
    private let rootViewController: ASDKNavigationController = {
        let navigationController = ASDKNavigationController()
        //navigationController.navigationBar.prefersLargeTitles = false
        
        return navigationController
    }()
    
    var root: any Presentable {
        return rootViewController
    }
    
    func navigate(to step: any Step) -> FlowContributors {
        guard let step = step as? AppStep else { return .none }
        switch step {
        case .authFlow:
            return navigateToAuthFlow()
        case .mainFlow:
            return navigateToMainFlow()
        }
    }
    
    // MARK: - Steps
    
    private func navigateToAuthFlow() -> FlowContributors {
        let viewModel = AuthViewModel()
        let authView = AuthView(viewModel: viewModel)
        let viewController = authView.wrapped()
        
        rootViewController.setViewControllers([viewController], animated: true)
        
        return .one(flowContributor: .contribute(
            withNextPresentable: viewController,
            withNextStepper: viewModel
        ))
    }
    
    private func navigateToMainFlow() -> FlowContributors {
        let mainFlow = MainFlow(rootViewController: rootViewController)
        guard let mainTabBarController = mainFlow.root as? UIViewController else {
            fatalError("MainFlow root must be UIViewController")
        }
        rootViewController.setViewControllers([mainTabBarController], animated: true)
        
        return .one(flowContributor: .contribute(
            withNextPresentable: mainFlow,
            withNextStepper: OneStepper(withSingleStep: MainStep.tabBarRequired)
        ))
    }
}
