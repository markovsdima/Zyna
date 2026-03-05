//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class AppCoordinator {

    let navigationController: ASDKNavigationController = {
        let nav = ASDKNavigationController()
        return nav
    }()

    func start() {
        showAuth()
    }

    // MARK: - Navigation

    private func showAuth() {
        let viewModel = AuthViewModel()
        viewModel.onAuthenticated = { [weak self] in
            self?.showMain()
        }
        let authView = AuthView(viewModel: viewModel)
        let vc = authView.wrapped()
        navigationController.setViewControllers([vc], animated: true)
    }

    private func showMain() {
        let mainCoordinator = MainCoordinator()
        mainCoordinator.start()

        guard let tabBar = mainCoordinator.tabBarController as? UIViewController else { return }
        navigationController.setViewControllers([tabBar], animated: true)
    }
}
