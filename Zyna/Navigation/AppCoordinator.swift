//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class AppCoordinator {

    weak var window: UIWindow?

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
        window?.rootViewController = vc
    }

    private func showMain() {
        let mainCoordinator = MainCoordinator()
        mainCoordinator.start()

        guard let tabBar = mainCoordinator.tabBarController as? UIViewController else { return }
        window?.rootViewController = tabBar
    }
}
