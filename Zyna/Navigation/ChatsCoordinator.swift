//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ChatsCoordinator {

    let navigationController = ASDKNavigationController()

    func start() {
        let vc = ChatsListViewController()
        vc.onChatSelected = { [weak self] chatId in
            self?.showChat(chatId)
        }
        navigationController.setViewControllers([vc], animated: false)
    }

    private func showChat(_ chatId: String) {
        let vc = ChatViewController(chatId: chatId)
        vc.onBack = { [weak self] in
            self?.navigationController.popViewController(animated: true)
        }
        navigationController.pushViewController(vc, animated: true)
    }
}
