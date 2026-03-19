//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK

// MARK: - Verification Step

enum VerificationStep: Equatable {
    case initial
    case requestingVerification
    case waitingForAcceptance
    case showingEmojis([SessionVerificationEmoji])
    case verified
    case cancelled
    case failed

    static func == (lhs: VerificationStep, rhs: VerificationStep) -> Bool {
        switch (lhs, rhs) {
        case (.initial, .initial),
             (.requestingVerification, .requestingVerification),
             (.waitingForAcceptance, .waitingForAcceptance),
             (.verified, .verified),
             (.cancelled, .cancelled),
             (.failed, .failed):
            return true
        case (.showingEmojis(let lhsEmojis), .showingEmojis(let rhsEmojis)):
            return lhsEmojis.count == rhsEmojis.count
        default:
            return false
        }
    }
}

private let logVerify = ScopedLog(.auth)

// MARK: - Session Verification Service

final class SessionVerificationService {

    let stepSubject = CurrentValueSubject<VerificationStep, Never>(.initial)

    private let matrixService = MatrixClientService.shared
    private var controller: SessionVerificationController?

    // MARK: - State Check

    var isVerified: Bool {
        matrixService.client?.encryption().verificationState() == .verified
    }

    // MARK: - Setup

    func setup() async throws {
        guard let client = matrixService.client else {
            throw VerificationError.clientNotAvailable
        }

        let controller = try await client.getSessionVerificationController()
        self.controller = controller

        let delegate = VerificationDelegate { [weak self] step in
            DispatchQueue.main.async {
                self?.stepSubject.send(step)
            }
        }
        delegate.setController(controller)
        controller.setDelegate(delegate: delegate)
        self.delegate = delegate

        logVerify("Verification controller ready")
    }

    private var delegate: VerificationDelegate?

    // MARK: - Actions

    func requestDeviceVerification() async throws {
        guard let controller else { throw VerificationError.controllerNotReady }
        stepSubject.send(.requestingVerification)
        try await controller.requestDeviceVerification()
        logVerify("Device verification requested")
    }

    func approveVerification() async throws {
        guard let controller else { throw VerificationError.controllerNotReady }
        try await controller.approveVerification()
        logVerify("Verification approved")
    }

    func declineVerification() async throws {
        guard let controller else { throw VerificationError.controllerNotReady }
        try await controller.declineVerification()
        logVerify("Verification declined")
    }

    func cancelVerification() async throws {
        guard let controller else { throw VerificationError.controllerNotReady }
        try await controller.cancelVerification()
        logVerify("Verification cancelled")
    }
}

// MARK: - Errors

enum VerificationError: LocalizedError {
    case clientNotAvailable
    case controllerNotReady

    var errorDescription: String? {
        switch self {
        case .clientNotAvailable: return "Matrix client is not available"
        case .controllerNotReady: return "Verification controller is not ready"
        }
    }
}

// MARK: - SDK Delegate

private final class VerificationDelegate: SessionVerificationControllerDelegate {
    private let onStep: (VerificationStep) -> Void
    private var controller: SessionVerificationController?

    init(onStep: @escaping (VerificationStep) -> Void) {
        self.onStep = onStep
    }

    func setController(_ controller: SessionVerificationController) {
        self.controller = controller
    }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        logVerify("Received verification request from \(details.deviceId)")
    }

    func didAcceptVerificationRequest() {
        logVerify("Verification request accepted, starting SAS")
        onStep(.waitingForAcceptance)
        Task {
            try? await controller?.startSasVerification()
        }
    }

    func didStartSasVerification() {
        logVerify("SAS verification started, waiting for emojis")
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        switch data {
        case .emojis(let emojis, _):
            logVerify("Received \(emojis.count) verification emojis")
            onStep(.showingEmojis(emojis))
        case .decimals:
            break
        }
    }

    func didFail() {
        logVerify("Verification failed")
        onStep(.failed)
    }

    func didCancel() {
        logVerify("Verification cancelled")
        onStep(.cancelled)
    }

    func didFinish() {
        logVerify("Verification finished successfully")
        onStep(.verified)
    }
}
