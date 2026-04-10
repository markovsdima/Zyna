//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

/// Which flow the screen is currently presenting.
/// Determined on appearance via `isLastDevice()`.
enum VerificationMode {
    case checking      // determining which flow to use
    case firstDevice   // no other devices — generate recovery key
    case otherDevice   // verify against existing device with emojis
}

final class SessionVerificationViewModel: ObservableObject {

    @Published var mode: VerificationMode = .checking
    @Published var step: VerificationStep = .initial
    @Published var emojis: [SessionVerificationEmoji] = []
    @Published var recoveryKey: String?
    @Published var recoveryKeyInput: String = ""
    @Published var errorMessage: String?

    var onVerified: (() -> Void)?
    var onSkipped: (() -> Void)?

    private let service = SessionVerificationService()
    private var cancellables = Set<AnyCancellable>()

    init() {
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
                // Emoji verification finished from SDK delegate —
                // cross-signing secrets are now on this device.
                if case .verified = step {
                    self.service.markLocalSecretsPresent()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Mode Detection

    func detectMode() {
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

    // MARK: - Other-Device Flow (emoji)

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

    // MARK: - Common

    func skip() {
        onSkipped?()
    }

    func continueToApp() {
        onVerified?()
    }
}
