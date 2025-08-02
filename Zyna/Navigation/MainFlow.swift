//
//  MainFlow.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 04.07.2025.
//

import RxFlow
import AsyncDisplayKit

enum MainStep: Step {
    case tabBarRequired
}

class MainFlow: Flow {
    
    var root: any Presentable {
        return rootViewController
    }
    
    var rootViewController: ASTabBarController
    
    init(rootViewController: ASDKNavigationController? = nil) {
        self.rootViewController = MainTabBarController()
    }
    
    func navigate(to step: any Step) -> FlowContributors {
        guard let step = step as? MainStep else {
            print("Step is not MainStep: \(step)")
            return .none
        }
        
        switch step {
        case .tabBarRequired:
            return setupTabs()
        }
    }
    
    private func setupTabs() -> FlowContributors {
        let chatsFlow = ChatsFlow()
        let profileFlow = ProfileFlow()
        let settingsFlow = SettingsFlow()
        
        let chatsTab = createTab(for: chatsFlow, title: "Чаты", icon: UIImage(systemName: "message"))
        let profileTab = createTab(for: profileFlow, title: "Профиль", icon: UIImage(systemName: "person"))
        let settingsTab = createTab(for: settingsFlow, title: "Настройки", icon: UIImage(systemName: "gear"))
        
        rootViewController.setViewControllers([profileTab, chatsTab, settingsTab], animated: false)
        rootViewController.selectedIndex = 1
        
        return .multiple(flowContributors: [
            .contribute(
                withNextPresentable: chatsFlow,
                withNextStepper: OneStepper(withSingleStep: ChatsStep.chatsList)
            ),
            .contribute(
                withNextPresentable: profileFlow,
                withNextStepper: OneStepper(withSingleStep: ProfileStep.profile)
            ),
            .contribute(
                withNextPresentable: settingsFlow,
                withNextStepper: OneStepper(withSingleStep: SettingsStep.settings)
            )
        ])
    }
    
    private func createTab(for flow: Flow, title: String, icon: UIImage?) -> ASDKNavigationController {
        guard let navController = flow.root as? ASDKNavigationController else {
            fatalError("Root must be ASDKNavigationController")
        }
        navController.tabBarItem = UITabBarItem(title: title, image: icon, selectedImage: nil)
        return navController
    }
}
