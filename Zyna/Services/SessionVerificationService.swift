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
    case generatingRecoveryKey
    case showingRecoveryKey(String)
    case enteringRecoveryKey
    case restoringFromRecoveryKey
    case verified
    case cancelled
    case failed

    static func == (lhs: VerificationStep, rhs: VerificationStep) -> Bool {
        switch (lhs, rhs) {
        case (.initial, .initial),
             (.requestingVerification, .requestingVerification),
             (.waitingForAcceptance, .waitingForAcceptance),
             (.generatingRecoveryKey, .generatingRecoveryKey),
             (.enteringRecoveryKey, .enteringRecoveryKey),
             (.restoringFromRecoveryKey, .restoringFromRecoveryKey),
             (.verified, .verified),
             (.cancelled, .cancelled),
             (.failed, .failed):
            return true
        case (.showingEmojis(let lhsEmojis), .showingEmojis(let rhsEmojis)):
            return lhsEmojis.count == rhsEmojis.count
        case (.showingRecoveryKey(let l), .showingRecoveryKey(let r)):
            return l == r
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

    // MARK: - Local Cross-Signing Secrets Flag
    //
    // The SDK can't tell us "does this device have the cross-signing
    // private keys locally?", which is the question we actually need
    // to answer to skip the verification screen on launch:
    //
    // - `verificationState == .verified` only fires after SAS
    //   verification by another device — never on single-device
    //   accounts.
    // - `recoveryState == .incomplete` is ambiguous: it can mean
    //   "fresh setup, no backup yet" (local has the keys) OR
    //   "re-installed device, secrets need to be fetched" (local
    //   has nothing).
    //
    // We track this ourselves: set the flag after `enableRecovery`
    // (we just created the keys locally) or after `recover` (we
    // just downloaded them). Cleared on logout. Naturally absent
    // after an app uninstall, because UserDefaults is wiped with
    // the app — that's exactly the re-install case where we want
    // the verification screen to come back up.

    private static let localSecretsKeyPrefix = "com.zyna.encryption.localSecrets."

    private var localSecretsKey: String? {
        guard let userId = try? matrixService.client?.userId() else { return nil }
        return Self.localSecretsKeyPrefix + userId
    }

    var hasLocalSecrets: Bool {
        guard let key = localSecretsKey else { return false }
        return UserDefaults.standard.bool(forKey: key)
    }

    func markLocalSecretsPresent() {
        guard let key = localSecretsKey else { return }
        UserDefaults.standard.set(true, forKey: key)
        logVerify("Local secrets flag set: \(key)")
    }

    static func clearLocalSecretsFlag(userId: String) {
        UserDefaults.standard.removeObject(forKey: localSecretsKeyPrefix + userId)
    }

    // MARK: - State Check

    /// Decides whether to skip the verification screen on launch.
    /// Returns true if `hasLocalSecrets` is set, or if the SDK
    /// reports `.verified` on `verificationState` within `timeout`
    /// (cross-device SAS path). Defaults to false on timeout — the
    /// safe choice is to show the screen.
    func awaitVerificationState(timeout: TimeInterval = 3.0) async -> Bool {
        if hasLocalSecrets {
            logVerify("awaitVerificationState: positive (local secrets flag)")
            return true
        }

        let vSubject = matrixService.verificationStateSubject

        if vSubject.value == .verified {
            logVerify("awaitVerificationState: positive (sync) v=\(vSubject.value)")
            return true
        }

        let work = Task<Bool?, Never> {
            for await vState in vSubject.values {
                if vState == .verified {
                    logVerify("awaitVerificationState: positive v=\(vState)")
                    return true
                }
                if vState != .unknown {
                    logVerify("awaitVerificationState: negative v=\(vState)")
                    return false
                }
            }
            return nil
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            work.cancel()
        }

        let result = await work.value
        timeoutTask.cancel()
        if result == nil {
            logVerify("awaitVerificationState: timed out after \(timeout)s; defaulting to false")
        }
        return result ?? false
    }

    /// Returns true if this is the only device on the account.
    /// First-device login → recovery key flow.
    /// Other devices exist → emoji verification flow.
    func isLastDevice() async throws -> Bool {
        guard let client = matrixService.client else {
            throw VerificationError.clientNotAvailable
        }
        return try await client.encryption().isLastDevice()
    }

    /// Bootstrap cross-signing and generate a recovery key.
    ///
    /// If the account already has recovery set up on the server
    /// (`recoveryState != .disabled`), we call `resetRecoveryKey()`
    /// instead — calling `enableRecovery` on top of an existing
    /// setup throws `RecoveryError.BackupExistsOnServer`. This is
    /// the same approach Element X uses.
    func enableRecovery() async throws -> String {
        guard let client = matrixService.client else {
            throw VerificationError.clientNotAvailable
        }
        let encryption = client.encryption()
        let initialRecoveryState = encryption.recoveryState()
        logVerify("enableRecovery: starting; verificationState=\(encryption.verificationState()) recoveryState=\(initialRecoveryState)")

        do {
            let key: String
            if initialRecoveryState == .disabled {
                let progress = RecoveryProgressListener { state in
                    logVerify("Recovery progress: \(state)")
                }
                key = try await encryption.enableRecovery(
                    waitForBackupsToUpload: false,
                    passphrase: nil,
                    progressListener: progress
                )
            } else {
                logVerify("enableRecovery: existing recovery detected, calling resetRecoveryKey")
                key = try await encryption.resetRecoveryKey()
            }
            logVerify("enableRecovery: done; key length=\(key.count) recoveryState=\(encryption.recoveryState())")
            return key
        } catch {
            logVerify("enableRecovery FAILED: \(error)")
            throw error
        }
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

    /// Restore this device using a previously generated recovery
    /// key. Used when re-installing on a device that lost its keys
    /// (e.g. wiped simulator) and there's no live peer to run
    /// emoji verification against.
    ///
    /// `encryption.recover()` reads `m.secret_storage.default_key`
    /// from the user's account data. On a fresh install that data
    /// hasn't been synced yet, and an early call throws "info about
    /// the secret key could not have been found". `waitForAccount
    /// DataReady` gates the call until the SDK signals it has the
    /// secret storage info.
    func recover(key: String) async throws {
        guard let client = matrixService.client else {
            throw VerificationError.clientNotAvailable
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        await waitForAccountDataReady(timeout: 10)

        let encryption = client.encryption()
        logVerify("recover: attempting; recoveryState=\(encryption.recoveryState()); key length=\(trimmed.count)")
        do {
            try await encryption.recover(recoveryKey: trimmed)
            logVerify("recover: success")
        } catch {
            // Retry once after a short pause — sometimes account data
            // arrives between our wait and the recover call, and the
            // first attempt races the listener.
            logVerify("recover: first attempt FAILED: \(error); retrying after 2s")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            logVerify("recover: retry; recoveryState=\(encryption.recoveryState())")
            do {
                try await encryption.recover(recoveryKey: trimmed)
                logVerify("recover: success on retry")
            } catch {
                logVerify("recover: retry FAILED: \(error)")
                throw error
            }
        }
    }

    /// Waits for the recovery state listener to indicate that the
    /// SDK has finished loading account data. We treat anything
    /// other than `.unknown` and `.disabled` (i.e. `.enabled` /
    /// `.incomplete`) as definitively-loaded — those states are
    /// only set once the SDK has seen `m.secret_storage.default_key`.
    /// `.disabled` is ambiguous (could be the SDK's initial default
    /// or could be the actual server state), so we wait for it to
    /// change for a brief window before giving up.
    private func waitForAccountDataReady(timeout: TimeInterval) async {
        let rSubject = matrixService.recoveryStateSubject
        let initial = rSubject.value

        if initial == .enabled || initial == .incomplete {
            return
        }

        logVerify("waitForAccountDataReady: recoveryState=\(initial), waiting up to \(timeout)s for account data…")
        let work = Task {
            for await state in rSubject.values {
                if state == .enabled || state == .incomplete {
                    logVerify("waitForAccountDataReady: ready, recoveryState=\(state)")
                    return
                }
            }
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            work.cancel()
        }
        _ = await work.value
        timeoutTask.cancel()
        if Task.isCancelled == false {
            logVerify("waitForAccountDataReady: ended with recoveryState=\(rSubject.value)")
        }
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

// MARK: - Recovery Progress Listener

private final class RecoveryProgressListener: EnableRecoveryProgressListener {
    private let onProgress: (EnableRecoveryProgress) -> Void

    init(onProgress: @escaping (EnableRecoveryProgress) -> Void) {
        self.onProgress = onProgress
    }

    func onUpdate(status: EnableRecoveryProgress) {
        onProgress(status)
    }
}
