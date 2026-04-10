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
        if MatrixClientService.shared.hasStoredSession {
            showMain()
            restoreSessionInBackground()
        } else {
            showAuth()
        }
    }

    // MARK: - Navigation

    private func showAuth() {
        let viewModel = AuthViewModel()
        viewModel.onAuthenticated = { [weak self] in
            Task { await self?.showVerificationIfNeeded() }
        }
        let authView = AuthView(viewModel: viewModel)
        let vc = authView.wrapped()
        window?.rootViewController = vc
    }

    private func restoreSessionInBackground() {
        Task {
            do {
                try await MatrixClientService.shared.restoreSession()
                await MainActor.run { [weak self] in
                    self?.resumeHeartbeatIfNeeded()
                }
                await self.showVerificationIfNeeded(modal: true)
            } catch {
                await MainActor.run { [weak self] in
                    self?.showAuth()
                }
            }
        }
    }

    private func showVerificationIfNeeded(modal: Bool = false) async {
        let service = SessionVerificationService()
        let verified = await service.awaitVerificationState()
        await MainActor.run { [weak self] in
            self?.presentVerification(verified: verified, modal: modal)
        }
    }

    @MainActor
    private func presentVerification(verified: Bool, modal: Bool) {
        if verified {
            if !modal { showMain() }
            return
        }

        let viewModel = SessionVerificationViewModel()

        if modal {
            // Present over existing main screen
            viewModel.onVerified = { [weak self] in
                self?.window?.rootViewController?.dismiss(animated: true)
            }
            viewModel.onSkipped = { [weak self] in
                self?.window?.rootViewController?.dismiss(animated: true)
            }
            let vc = SessionVerificationView(viewModel: viewModel).wrapped()
            vc.modalPresentationStyle = .fullScreen
            window?.rootViewController?.present(vc, animated: true)
        } else {
            viewModel.onVerified = { [weak self] in self?.showMain() }
            viewModel.onSkipped = { [weak self] in self?.showMain() }
            let vc = SessionVerificationView(viewModel: viewModel).wrapped()
            window?.rootViewController = vc
        }
    }

    private func showMain() {
        let coordinator = MainCoordinator()
        coordinator.onLogout = { [weak self] in
            self?.performLogout()
        }
        coordinator.start()
        self.mainCoordinator = coordinator

        if let userId = MatrixClientService.shared.client.flatMap({ try? $0.userId() }) {
            PresenceService.shared.startHeartbeatLoop(userId: userId)
        }

        guard let tabBar = coordinator.tabBarController as? UIViewController else { return }
        window?.rootViewController = tabBar
    }

    func resumeHeartbeatIfNeeded() {
        guard let userId = MatrixClientService.shared.client.flatMap({ try? $0.userId() }) else { return }
        PresenceService.shared.startHeartbeatLoop(userId: userId)
    }

    private func performLogout() {
        PresenceService.shared.stopHeartbeatLoop()
        Task { @MainActor in
            await MatrixClientService.shared.logout()
            self.mainCoordinator = nil
            self.showAuth()
        }
    }
}
