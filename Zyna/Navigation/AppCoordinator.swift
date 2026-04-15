//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import SwiftUI
import Combine

final class AppCoordinator {

    weak var window: UIWindow?
    private var mainCoordinator: MainCoordinator?
    private var cancellables = Set<AnyCancellable>()

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
            Task {
                await self?.showVerificationIfNeeded()
                await self?.setupVerificationRequestListener()
            }
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
                await self.setupVerificationRequestListener()
            } catch {
                await MainActor.run { [weak self] in
                    self?.showAuth()
                }
            }
        }
    }

    private func showVerificationIfNeeded(modal: Bool = false) async {
        let service = SessionVerificationService.shared
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

    // MARK: - Incoming Verification Requests

    /// Sets up the verification controller and subscribes to incoming
    /// verification requests from other devices. When a request arrives,
    /// presents the verification screen in responder mode.
    private func setupVerificationRequestListener() async {
        do {
            try await SessionVerificationService.shared.setup()
        } catch {
            return
        }

        await MainActor.run { [weak self] in
            guard let self else { return }

            SessionVerificationService.shared.incomingRequestSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] request in
                    self?.presentResponderVerification(request: request)
                }
                .store(in: &self.cancellables)
        }
    }

    @MainActor
    private func presentResponderVerification(request: IncomingVerificationRequest) {
        // Don't present if already showing a verification screen
        guard window?.rootViewController?.presentedViewController == nil else { return }

        let viewModel = SessionVerificationViewModel(incomingRequest: request)
        viewModel.onVerified = { [weak self] in
            self?.window?.rootViewController?.dismiss(animated: true)
        }
        viewModel.onSkipped = { [weak self] in
            self?.window?.rootViewController?.dismiss(animated: true)
        }
        let vc = SessionVerificationView(viewModel: viewModel).wrapped()
        vc.modalPresentationStyle = .fullScreen
        window?.rootViewController?.present(vc, animated: true)
    }

    private func showMain() {
        let coordinator = MainCoordinator()
        coordinator.onLogout = { [weak self] in
            self?.performLogout()
        }
        coordinator.start()
        self.mainCoordinator = coordinator

        PresenceTracker.shared.connect()

        window?.rootViewController = coordinator.tabBarController
    }

    func resumeHeartbeatIfNeeded() {
        PresenceTracker.shared.connect()
    }

    private func performLogout() {
        PresenceTracker.shared.disconnect()
        Task { @MainActor in
            await MatrixClientService.shared.logout()
            self.mainCoordinator = nil
            self.showAuth()
        }
    }
}
