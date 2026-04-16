//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

/// Which flow the screen is currently presenting.
/// Determined on appearance via `isLastDevice()`, or set to
/// `.responder` when another device sends a verification request.
enum VerificationMode {
    case checking      // determining which flow to use
    case firstDevice   // no other devices — generate recovery key
    case otherDevice   // verify against existing device with emojis
    case responder     // another device requested verification from us
}

final class SessionVerificationViewModel: ObservableObject {

    @Published var mode: VerificationMode = .checking
    @Published var step: VerificationStep = .initial
    @Published var emojis: [SessionVerificationEmoji] = []
    @Published var recoveryKey: String?
    @Published var recoveryKeyInput: String = ""
    @Published var errorMessage: String?

    /// Incoming request details (responder mode only).
    private(set) var incomingRequest: IncomingVerificationRequest?

    var onVerified: (() -> Void)?
    var onSkipped: (() -> Void)?

    private let service = SessionVerificationService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        observeSteps()
    }

    /// Init for responder mode — when another device requested verification.
    init(incomingRequest: IncomingVerificationRequest) {
        self.incomingRequest = incomingRequest
        self.mode = .responder
        observeSteps()
        acknowledgeRequest(incomingRequest)
    }

    private func observeSteps() {
        service.stepSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] step in
                guard let self else { return }
                self.step = step
                if case .showingEmojis(let emojis) = step {
                    self.emojis = emojis
                }
                if case .showingRecoveryKey(let key) = step {
                    self.recoveryKey = key
                }
                // Emoji verification finished from SDK delegate.
                // Wait for secret gossiping to deliver backup keys.
                // If it doesn't arrive in time, prompt for recovery key.
                if case .verified = step {
                    if self.mode == .otherDevice {
                        self.waitForSecretGossiping()
                    } else {
                        self.service.markLocalSecretsPresent()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Mode Detection

    func detectMode() {
        // Responder mode is set at init, skip detection.
        guard mode != .responder else { return }

        Task {
            do {
                let isLast = try await service.isLastDevice()
                await MainActor.run {
                    self.mode = isLast ? .firstDevice : .otherDevice
                }
            } catch {
                // If we can't determine, assume other-device flow
                // (the existing/safer default).
                await MainActor.run {
                    self.mode = .otherDevice
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Other-Device Flow (emoji) — Initiator

    func startVerification() {
        errorMessage = nil
        Task {
            do {
                try await service.setup()
                try await service.requestDeviceVerification()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    step = .failed
                }
            }
        }
    }

    // MARK: - Responder Flow

    private func acknowledgeRequest(_ request: IncomingVerificationRequest) {
        Task {
            do {
                try await service.acknowledgeVerificationRequest(request)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    step = .failed
                }
            }
        }
    }

    func acceptIncomingRequest() {
        errorMessage = nil
        Task {
            do {
                try await service.acceptVerificationRequest()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    step = .failed
                }
            }
        }
    }

    func ignoreIncomingRequest() {
        onSkipped?()
    }

    // MARK: - Emoji Confirmation (shared by initiator & responder)

    func confirmEmojis() {
        Task {
            do {
                try await service.approveVerification()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    step = .failed
                }
            }
        }
    }

    func denyEmojis() {
        Task {
            try? await service.declineVerification()
        }
    }

    // MARK: - First-Device Flow (recovery key)

    func setupRecovery() {
        errorMessage = nil
        step = .generatingRecoveryKey
        Task {
            do {
                let key = try await service.enableRecovery()
                // We just created the cross-signing secrets locally.
                service.markLocalSecretsPresent()
                await MainActor.run {
                    self.recoveryKey = key
                    self.step = .showingRecoveryKey(key)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    step = .failed
                }
            }
        }
    }

    func confirmRecoveryKeySaved() {
        step = .verified
    }

    /// Destructive: resets existing recovery key and backup,
    /// then generates a new one. Old encrypted messages will be lost.
    func resetAndGenerateNewKey() {
        errorMessage = nil
        step = .generatingRecoveryKey
        Task {
            do {
                let key = try await service.forceResetRecovery()
                service.markLocalSecretsPresent()
                await MainActor.run {
                    self.recoveryKey = key
                    self.step = .showingRecoveryKey(key)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    step = .failed
                }
            }
        }
    }

    // MARK: - Restore From Recovery Key

    func useRecoveryKey() {
        errorMessage = nil
        recoveryKeyInput = ""
        step = .enteringRecoveryKey
    }

    func restoreFromRecoveryKey() {
        errorMessage = nil
        let key = recoveryKeyInput
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        step = .restoringFromRecoveryKey
        Task {
            do {
                try await service.recover(key: key)
                // Secrets just downloaded onto this device.
                service.markLocalSecretsPresent()
                await MainActor.run {
                    self.step = .verified
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.step = .failed
                }
            }
        }
    }

    // MARK: - Secret Gossiping

    /// After SAS verification, the SDK requests secrets from the other
    /// device. Wait up to 10s for `recoveryState` to become `.enabled`.
    /// If it does, secrets arrived via gossiping. If not, ask for recovery key.
    private func waitForSecretGossiping() {
        step = .waitingForSecrets
        Task {
            let rSubject = MatrixClientService.shared.recoveryStateSubject

            // If recovery isn't set up on the server, gossiping
            // has nothing to deliver — skip waiting.
            guard rSubject.value != .disabled else {
                await MainActor.run {
                    self.recoveryKeyInput = ""
                    self.step = .needsRecoveryKey
                }
                return
            }

            let timeout: UInt64 = 10_000_000_000 // 10 seconds

            // Skip the first emitted value (CurrentValueSubject replays
            // current state immediately) — wait for an actual change.
            let work = Task<Bool, Never> {
                var skippedInitial = false
                for await state in rSubject.values {
                    if !skippedInitial { skippedInitial = true; continue }
                    if state == .enabled { return true }
                }
                return false
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeout)
                work.cancel()
            }

            let received = await work.value
            timeoutTask.cancel()

            await MainActor.run {
                if received {
                    self.service.markLocalSecretsPresent()
                    self.step = .verified
                } else {
                    self.recoveryKeyInput = ""
                    self.step = .needsRecoveryKey
                }
            }
        }
    }

    // MARK: - Common

    func skip() {
        onSkipped?()
    }

    func continueToApp() {
        onVerified?()
    }
}
