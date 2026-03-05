//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import SwiftUI

final class AppCoordinator {

    weak var window: UIWindow?
    private var mainCoordinator: MainCoordinator?

    func start() {
        showAuth()
    }

    // MARK: - Navigation

    private func showAuth() {
        let viewModel = AuthViewModel()
        viewModel.onAuthenticated = { [weak self] in
            self?.showVerificationIfNeeded()
        }
        let authView = AuthView(viewModel: viewModel)
        let vc = authView.wrapped()
        window?.rootViewController = vc
    }

    private func showVerificationIfNeeded() {
        let service = SessionVerificationService()
        if service.isVerified {
            showMain()
            return
        }

        let viewModel = SessionVerificationViewModel()
        viewModel.onVerified = { [weak self] in self?.showMain() }
        viewModel.onSkipped = { [weak self] in self?.showMain() }
        let vc = SessionVerificationView(viewModel: viewModel).wrapped()
        window?.rootViewController = vc
    }

    private func showMain() {
        let coordinator = MainCoordinator()
        coordinator.start()
        self.mainCoordinator = coordinator

        guard let tabBar = coordinator.tabBarController as? UIViewController else { return }
        window?.rootViewController = tabBar
    }
}
