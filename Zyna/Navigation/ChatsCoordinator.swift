//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class ChatsCoordinator {

    let navigationController = ASDKNavigationController()

    func start() {
        let vc = ChatsListViewController()
        vc.onChatSelected = { [weak self] room in
            self?.showChat(room)
        }
        navigationController.setViewControllers([vc], animated: false)
    }

    private func showChat(_ room: Room) {
        let viewModel = ChatViewModel(room: room)
        let vc = ChatViewController(viewModel: viewModel)
        vc.onBack = { [weak self] in
            self?.navigationController.popViewController(animated: true)
        }
        navigationController.pushViewController(vc, animated: true)
    }
}
