//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

final class SessionVerificationViewModel: ObservableObject {

    @Published var step: VerificationStep = .initial
    @Published var emojis: [SessionVerificationEmoji] = []
    @Published var errorMessage: String?

    var onVerified: (() -> Void)?
    var onSkipped: (() -> Void)?

    private let service = SessionVerificationService()
    private var cancellables = Set<AnyCancellable>()

    init() {
        service.stepSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] step in
                self?.step = step
                if case .showingEmojis(let emojis) = step {
                    self?.emojis = emojis
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

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

    func skip() {
        onSkipped?()
    }

    func continueToApp() {
        onVerified?()
    }
}
