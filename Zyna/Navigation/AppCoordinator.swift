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
    private let backupUploadDeadline: Duration = .seconds(30)
    private let serverLogoutDeadline: Duration = .seconds(12)
    private var isShowingSessionRecovery = false
    private var sessionRestoreTask: Task<Void, Never>?

    func start() {
        observeClientState()
        observeNetworkRestoration()

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
                switch state {
                case .softLoggedOut:
                    guard !self.isPerformingLogout else { return }
                    Task { @MainActor in self.showSessionRecovery(mode: .softLogout) }
                    return
                case .sessionRecoveryRequired:
                    guard !self.isPerformingLogout else { return }
                    Task { @MainActor in self.showSessionRecovery(mode: .restoreFailure) }
                    return
                default:
                    break
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

    private func observeNetworkRestoration() {
        NetworkReachability.shared.onRestored = { [weak self] in
            DispatchQueue.main.async {
                self?.retrySessionRestoreAfterNetworkRestored()
            }
        }
        NetworkReachability.shared.start()
    }

    // MARK: - Navigation

    private func showAuth() {
        isShowingSessionRecovery = false
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
        guard sessionRestoreTask == nil else { return }

        sessionRestoreTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await MatrixClientService.shared.restoreSession()
                if case .error(let error) = MatrixClientService.shared.state,
                   MatrixClientService.isRetryableTransportError(error) {
                    await MainActor.run { [weak self] in
                        self?.sessionRestoreTask = nil
                    }
                    return
                }

                PushService.shared.registerIfNeeded()
                await MainActor.run { [weak self] in
                    self?.resumeHeartbeatIfNeeded()
                }
                await self.showVerificationIfNeeded(modal: true)
                await self.setupVerificationRequestListener()
            } catch {
                await MainActor.run { [weak self] in
                    self?.sessionRestoreTask = nil
                    if MatrixClientService.isRetryableTransportError(error) {
                        return
                    }
                    switch MatrixClientService.shared.state {
                    case .softLoggedOut, .sessionRecoveryRequired:
                        return
                    default:
                        break
                    }
                    self?.showAuth()
                }
                return
            }

            await MainActor.run { [weak self] in
                self?.sessionRestoreTask = nil
            }
        }
    }

    private func retrySessionRestoreAfterNetworkRestored() {
        guard MatrixClientService.shared.hasStoredSession else { return }
        guard !isPerformingLogout else { return }

        switch MatrixClientService.shared.state {
        case .softLoggedOut, .sessionRecoveryRequired, .syncing, .loggingIn, .loggedOut:
            return
        default:
            restoreSessionInBackground()
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
        isShowingSessionRecovery = false
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
    private func showSessionRecovery(mode: SessionRecoveryMode) {
        guard !isPerformingLogout else { return }
        guard !isShowingSessionRecovery else { return }
        isShowingSessionRecovery = true

        serverLogoutCompletionObserver?.cancel()
        serverLogoutCompletionObserver = nil
        serverLogoutTask?.cancel()
        serverLogoutTask = nil
        logoutFallbackAlert = nil
        isPerformingLogout = false

        PresenceTracker.shared.disconnect()
        mainCoordinator?.stopVoicePlayback()
        mainCoordinator = nil

        let viewModel = SessionRecoveryViewModel(
            credentials: MatrixClientService.shared.sessionRecoveryCredentials,
            mode: mode
        )
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

        window?.rootViewController = SessionRecoveryView(viewModel: viewModel).wrapped()
    }

    func resumeHeartbeatIfNeeded() {
        PresenceTracker.shared.connect()
    }

    @MainActor
    private func performLogout() async {
        guard !isPerformingLogout else {
            if logoutFallbackAlert == nil, serverLogoutTask != nil {
                presentLocalLogoutFallback()
            }
            return
        }
        isPerformingLogout = true

        guard await waitForBackupUploadBeforeLogout() else {
            return
        }

        await startServerLogout()
    }

    @MainActor
    private func waitForBackupUploadBeforeLogout() async -> Bool {
        let progressAlert = makeLogoutProgressAlert(
            title: String(localized: "Saving Message Keys"),
            message: String(localized: "Checking that message keys are saved to the encrypted backup on your homeserver.")
        )
        presentOnTop(progressAlert)

        let backupTask = Task {
            do {
                try await MatrixClientService.shared.waitForBackupUploadSteadyState()
            } catch let failure as BackupUploadWaitFailure where failure.isBackupDisabled {
                try await MatrixClientService.shared.enableKeyBackup()
                try await MatrixClientService.shared.waitForBackupUploadSteadyState()
            }
        }

        do {
            try await waitForCompletion(of: backupTask, timeout: backupUploadDeadline)
            await dismiss(progressAlert)
            return true
        } catch LogoutWaitError.timedOut {
            backupTask.cancel()
            await dismiss(progressAlert)
            isPerformingLogout = false
            presentBackupUploadRiskAlert(failure: .timedOut)
            return false
        } catch let failure as BackupUploadWaitFailure {
            backupTask.cancel()
            await dismiss(progressAlert)
            isPerformingLogout = false
            presentBackupUploadRiskAlert(failure: failure)
            return false
        } catch {
            backupTask.cancel()
            await dismiss(progressAlert)
            isPerformingLogout = false
            presentBackupUploadRiskAlert(failure: .unknown)
            return false
        }
    }

    @MainActor
    private func startServerLogout() async {
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
    private func makeLogoutProgressAlert(
        title: String = String(localized: "Signing Out"),
        message: String = ""
    ) -> UIAlertController {
        let alert = UIAlertController(
            title: title,
            message: message + "\n\n",
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
    private func presentBackupUploadRiskAlert(failure: BackupUploadWaitFailure) {
        let message = backupUploadRiskMessage(for: failure)
        let alert = UIAlertController(
            title: backupUploadRiskTitle(for: failure),
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.logoutFallbackAlert = nil
            self?.isPerformingLogout = false
        })
        if !failure.isBackupDisabled {
            alert.addAction(UIAlertAction(title: String(localized: "Try Again"), style: .default) { [weak self] _ in
                Task { @MainActor in
                    self?.logoutFallbackAlert = nil
                    await self?.performLogout()
                }
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Sign Out Anyway"), style: .destructive) { [weak self] _ in
            Task { @MainActor in
                self?.logoutFallbackAlert = nil
                await self?.startServerLogout()
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Remove Local Data"), style: .destructive) { [weak self] _ in
            Task { @MainActor in
                self?.logoutFallbackAlert = nil
                await self?.finishLocalLogout()
            }
        })

        logoutFallbackAlert = alert
        presentOnTop(alert)
    }

    private func backupUploadRiskTitle(for failure: BackupUploadWaitFailure) -> String {
        switch failure {
        case .backupDisabled:
            return String(localized: "Encrypted Key Backup Is Off")
        case .timedOut, .connection, .lagged, .unknown:
            return String(localized: "Message Keys Are Not Fully Saved")
        }
    }

    private func backupUploadRiskMessage(for failure: BackupUploadWaitFailure) -> String {
        let body: String
        if failure.isBackupDisabled {
            body = String(localized: "Encrypted key backup on your homeserver is off, so message keys that exist only on this device are not saved there. The homeserver stores these keys encrypted; it cannot read your messages.\n\nIf this is your only session with those keys, some recent encrypted messages that depend on them will not be recoverable after local data is removed. Entering your recovery key later only restores keys that were already saved to the server backup.\n\nCancel, set up recovery, and try again, or continue only if another verified session already has the needed message keys or you accept losing access to some recent encrypted messages.\n\nSign Out Anyway asks the server to sign out first, then removes local data from this device. Remove Local Data skips server sign-out and deletes local data from this device.")
        } else {
            body = String(localized: "Zyna could not confirm that this device finished uploading its message keys to the encrypted backup on your homeserver. The homeserver stores these keys encrypted; it cannot read your messages.\n\nIf any unuploaded keys exist only on this device, some recent encrypted messages that depend on them will not be recoverable after local data is removed. Entering your recovery key later only restores keys that were already saved to the server backup.\n\nWait and try again unless you know those keys are backed up on the server, another verified session already has the needed message keys, or you accept losing access to some recent encrypted messages.\n\nSign Out Anyway asks the server to sign out first, then removes local data from this device. Remove Local Data skips server sign-out and deletes local data from this device.")
        }
        return body + "\n\n" + String(localized: "Reason:") + " " + backupUploadRiskReason(for: failure)
    }

    private func backupUploadRiskReason(for failure: BackupUploadWaitFailure) -> String {
        switch failure {
        case .timedOut:
            return String(localized: "Backup check timed out.")
        case .backupDisabled:
            return String(localized: "Encrypted server key backup is disabled.")
        case .connection:
            return String(localized: "Network connection failed while checking backup.")
        case .lagged:
            return String(localized: "Backup upload is still catching up.")
        case .unknown:
            return String(localized: "Backup check failed.")
        }
    }

    @MainActor
    private func presentLocalLogoutFallback(canKeepWaiting: Bool = true) {
        let alert = UIAlertController(
            title: String(localized: "Sign Out Is Taking Too Long"),
            message: canKeepWaiting
                ? String(localized: "Signing out is taking longer than expected. You can keep waiting.\n\nZyna already checked that message keys were saved to the encrypted backup on your homeserver before starting server sign-out. Remove Local Data skips server sign-out and deletes this device's local session data, including local copies of message keys. Backed-up keys can be restored later with your recovery key or another verified session, but the server-side session may remain active.")
                : String(localized: "The server did not complete sign-out. You can stay signed in here.\n\nZyna already checked that message keys were saved to the encrypted backup on your homeserver before starting server sign-out. Remove Local Data skips server sign-out and deletes this device's local session data, including local copies of message keys. Backed-up keys can be restored later with your recovery key or another verified session, but the server-side session may remain active."),
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
        alert.addAction(UIAlertAction(title: String(localized: "Remove Local Data"), style: .destructive) { [weak self] _ in
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
