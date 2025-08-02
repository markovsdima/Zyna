//
//  ChatsTabFlow.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 04.07.2025.
//

import RxFlow
import AsyncDisplayKit

enum ChatsStep: Step {
    case chatsList
    case chat
    case back
}

class ChatsFlow: Flow {
    var root: Presentable { return rootNavController }
    private let rootNavController = ASDKNavigationController()
    
    func navigate(to step: Step) -> FlowContributors {
        guard let step = step as? ChatsStep else { return .none }
        switch step {
        case .chatsList:
            let vc = ChatsListViewController()
            rootNavController.setViewControllers([vc], animated: false)
            return .one(flowContributor: .contribute(
                withNextPresentable: vc,
                withNextStepper: vc
            ))
        case .chat:
            let vc = ChatViewController(chatId: "123")
            rootNavController.pushViewController(vc, animated: true)
            return .one(flowContributor: .contribute(withNext: vc))
        case .back:
            return navigateBack()
        }
    }
    
    private func navigateBack() -> FlowContributors {
        rootNavController.popViewController(animated: true)
        return .none
    }
}
