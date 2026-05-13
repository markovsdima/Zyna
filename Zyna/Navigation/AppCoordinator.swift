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
    private var isPerformingLogout = false
    private var serverLogoutTask: Task<Void, Error>?
    private var serverLogoutCompletionObserver: Task<Void, Never>?
    private weak var logoutFallbackAlert: UIAlertController?
    private let serverLogoutDeadline: Duration = .seconds(12)
    private var isShowingSoftLogout = false

    func start() {
        observeClientState()

        if MatrixClientService.shared.hasStoredSession {
            showMain()
            restoreSessionInBackground()
        } else {
            showAuth()
        }
    }

    private func observeClientState() {
        MatrixClientService.shared.stateSubject
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if case .softLoggedOut = state {
                    Task { @MainActor in
                        self.showSoftLogout()
                    }
                    return
                }
                guard case .loggedOut = state else { return }
                guard self.mainCoordinator != nil else { return }
                guard !self.isPerformingLogout || self.serverLogoutTask != nil else { return }

                self.serverLogoutCompletionObserver?.cancel()
                self.serverLogoutCompletionObserver = nil
                self.serverLogoutTask?.cancel()
                self.serverLogoutTask = nil
                self.logoutFallbackAlert = nil
                PresenceTracker.shared.disconnect()
                self.mainCoordinator?.stopVoicePlayback()
                self.mainCoordinator = nil
                self.showAuth()
                self.isPerformingLogout = false
            }
            .store(in: &cancellables)
    }

    // MARK: - Navigation

    private func showAuth() {
        isShowingSoftLogout = false
        let viewModel = AuthViewModel()
        viewModel.onAuthenticated = { [weak self] in
            PushService.shared.registerIfNeeded()
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
                PushService.shared.registerIfNeeded()
                await MainActor.run { [weak self] in
                    self?.resumeHeartbeatIfNeeded()
                }
                await self.showVerificationIfNeeded(modal: true)
                await self.setupVerificationRequestListener()
            } catch {
                await MainActor.run { [weak self] in
                    if case .softLoggedOut = MatrixClientService.shared.state {
                        return
                    }
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
        isShowingSoftLogout = false
        let coordinator = MainCoordinator()
        coordinator.onLogout = { [weak self] in
            Task { @MainActor in
                await self?.performLogout()
            }
        }
        coordinator.start()
        self.mainCoordinator = coordinator

        PresenceTracker.shared.connect()

        window?.rootViewController = coordinator.tabBarController
    }

    @MainActor
    private func showSoftLogout() {
        guard !isShowingSoftLogout else { return }
        isShowingSoftLogout = true

        serverLogoutCompletionObserver?.cancel()
        serverLogoutCompletionObserver = nil
        serverLogoutTask?.cancel()
        serverLogoutTask = nil
        logoutFallbackAlert = nil
        isPerformingLogout = false

        PresenceTracker.shared.disconnect()
        mainCoordinator?.stopVoicePlayback()
        mainCoordinator = nil

        let viewModel = SoftLogoutViewModel(credentials: MatrixClientService.shared.softLogoutCredentials)
        viewModel.onAuthenticated = { [weak self] in
            PushService.shared.registerIfNeeded()
            Task {
                await self?.showVerificationIfNeeded()
                await self?.setupVerificationRequestListener()
            }
        }
        viewModel.onClearData = { [weak self] in
            Task { @MainActor in
                await MatrixClientService.shared.logoutLocally()
                self?.showAuth()
            }
        }

        window?.rootViewController = SoftLogoutView(viewModel: viewModel).wrapped()
    }

    func resumeHeartbeatIfNeeded() {
        PresenceTracker.shared.connect()
    }

    @MainActor
    private func performLogout() async {
        guard !isPerformingLogout else {
            if logoutFallbackAlert == nil {
                presentLocalLogoutFallback()
            }
            return
        }
        isPerformingLogout = true

        serverLogoutCompletionObserver?.cancel()
        serverLogoutCompletionObserver = nil
        serverLogoutTask = Task {
            try await MatrixClientService.shared.logoutFromServer()
        }

        await waitForServerLogout()
    }

    @MainActor
    private func waitForServerLogout() async {
        guard let serverLogoutTask else {
            isPerformingLogout = false
            return
        }

        await Task.yield()

        let progressAlert = makeLogoutProgressAlert()
        presentOnTop(progressAlert)

        do {
            try await waitForCompletion(of: serverLogoutTask, timeout: serverLogoutDeadline)
            await dismiss(progressAlert)
            await finishLocalLogout()
        } catch LogoutWaitError.timedOut {
            await dismiss(progressAlert)
            presentLocalLogoutFallback()
            observeServerLogoutCompletion()
        } catch {
            self.serverLogoutTask = nil
            await dismiss(progressAlert)
            presentLocalLogoutFallback(canKeepWaiting: false)
        }
    }

    @MainActor
    private func finishLocalLogout() async {
        serverLogoutCompletionObserver?.cancel()
        serverLogoutCompletionObserver = nil
        serverLogoutTask?.cancel()
        serverLogoutTask = nil
        logoutFallbackAlert = nil
        PresenceTracker.shared.disconnect()
        mainCoordinator?.stopVoicePlayback()
        await MatrixClientService.shared.logoutLocally()
        mainCoordinator = nil
        showAuth()
        isPerformingLogout = false
    }

    @MainActor
    private func makeLogoutProgressAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "Signing Out"),
            message: "\n\n",
            preferredStyle: .alert
        )
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        alert.view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -24)
        ])
        return alert
    }

    @MainActor
    private func presentLocalLogoutFallback(canKeepWaiting: Bool = true) {
        let alert = UIAlertController(
            title: String(localized: "Server Is Not Responding"),
            message: canKeepWaiting
                ? String(localized: "Signing out is taking longer than expected. You can keep waiting or remove this account from this device.")
                : String(localized: "The server did not complete sign out. You can stay signed in here or remove this account from this device."),
            preferredStyle: .alert
        )
        if canKeepWaiting {
            alert.addAction(UIAlertAction(title: String(localized: "Keep Waiting"), style: .default) { [weak self] _ in
                Task { @MainActor in
                    self?.logoutFallbackAlert = nil
                    self?.serverLogoutCompletionObserver?.cancel()
                    self?.serverLogoutCompletionObserver = nil
                    await self?.waitForServerLogout()
                }
            })
            alert.addAction(UIAlertAction(title: String(localized: "Stop Waiting"), style: .cancel) { [weak self] _ in
                self?.logoutFallbackAlert = nil
            })
        } else {
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
                self?.logoutFallbackAlert = nil
                self?.isPerformingLogout = false
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Sign Out on This Device"), style: .destructive) { [weak self] _ in
            Task { @MainActor in
                await self?.finishLocalLogout()
            }
        })

        logoutFallbackAlert = alert
        presentOnTop(alert)
    }

    @MainActor
    private func presentOnTop(_ viewController: UIViewController) {
        guard var presenter = window?.rootViewController else { return }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(viewController, animated: true)
    }

    @MainActor
    private func dismiss(_ viewController: UIViewController) async {
        guard viewController.presentingViewController != nil else { return }

        await withCheckedContinuation { continuation in
            viewController.dismiss(animated: true) {
                continuation.resume()
            }
        }
    }

    private func waitForCompletion(of task: Task<Void, Error>, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let continuation = OneShotContinuation(continuation)

            Task {
                do {
                    try await task.value
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            Task {
                do {
                    try await Task.sleep(for: timeout)
                    continuation.resume(throwing: LogoutWaitError.timedOut)
                } catch {}
            }
        }
    }

    private func observeServerLogoutCompletion() {
        guard serverLogoutCompletionObserver == nil, let serverLogoutTask else { return }

        serverLogoutCompletionObserver = Task { [weak self] in
            do {
                try await serverLogoutTask.value
                await self?.completeLogoutAfterLateServerSuccess()
            } catch {
                await self?.stopObservingServerLogoutCompletion()
            }
        }
    }

    @MainActor
    private func completeLogoutAfterLateServerSuccess() async {
        guard mainCoordinator != nil else { return }

        serverLogoutCompletionObserver = nil
        if let logoutFallbackAlert {
            await dismiss(logoutFallbackAlert)
        }
        await finishLocalLogout()
    }

    @MainActor
    private func stopObservingServerLogoutCompletion() {
        serverLogoutCompletionObserver = nil
        serverLogoutTask = nil
        logoutFallbackAlert = nil
        isPerformingLogout = false
    }
}

private enum LogoutWaitError: Error {
    case timedOut
}

private final class OneShotContinuation<Success>: @unchecked Sendable {
    private let continuation: Atomic<CheckedContinuation<Success, Error>?>

    init(_ continuation: CheckedContinuation<Success, Error>) {
        self.continuation = Atomic(continuation)
    }

    func resume(returning value: Success) {
        resume(with: .success(value))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Success, Error>) {
        let continuation = continuation.withValue { stored in
            let current = stored
            stored = nil
            return current
        }
        continuation?.resume(with: result)
    }
}
