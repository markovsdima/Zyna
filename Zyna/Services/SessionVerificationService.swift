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
    case acceptingRequest // responder: user tapped Accept, calling SDK
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
             (.acceptingRequest, .acceptingRequest),
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

// MARK: - Incoming Verification Request

struct IncomingVerificationRequest {
    let senderId: String
    let flowId: String
    let deviceId: String
    let deviceDisplayName: String?
}

private let logVerify = ScopedLog(.auth)

// MARK: - Session Verification Service

final class SessionVerificationService {

    static let shared = SessionVerificationService()

    let stepSubject = CurrentValueSubject<VerificationStep, Never>(.initial)

    /// Fires when another device sends a verification request to this device.
    let incomingRequestSubject = PassthroughSubject<IncomingVerificationRequest, Never>()

    private let matrixService = MatrixClientService.shared
    private var controller: SessionVerificationController?
    private var delegate: VerificationDelegate?
    private var isControllerReady = false
    /// True when this device initiated the verification request.
    /// Only the initiator calls startSasVerification() after acceptance.
    private(set) var isInitiator = false

    private init() {}

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
            // Check if cross-signing identity actually exists on the server.
            // recoveryState can be .incomplete/.enabled even when cross-signing
            // was never bootstrapped (partial state from a failed attempt).
            // Only use resetRecoveryKey() when identity is confirmed present.
            let userId = try client.userId()
            let identity = try? await encryption.userIdentity(userId: userId, fallbackToServer: true)
            let hasCrossSigning = identity != nil
            logVerify("enableRecovery: cross-signing identity = \(hasCrossSigning)")

            let key: String
            if hasCrossSigning && (initialRecoveryState == .enabled || initialRecoveryState == .incomplete) {
                logVerify("enableRecovery: cross-signing exists, calling resetRecoveryKey")
                key = try await encryption.resetRecoveryKey()
            } else {
                // No cross-signing — bootstrap from scratch.
                // If a previous broken attempt left a backup on the server,
                // disableRecovery() first to clear it, otherwise
                // enableRecovery() throws BackupExistsOnServer.
                if !hasCrossSigning && initialRecoveryState != .disabled {
                    logVerify("enableRecovery: clearing orphaned recovery state")
                    do {
                        try await encryption.disableRecovery()
                        logVerify("enableRecovery: disableRecovery succeeded, recoveryState=\(encryption.recoveryState())")
                    } catch {
                        logVerify("enableRecovery: disableRecovery failed: \(error)")
                    }

                    // Also delete backup via Matrix API as a fallback
                    let backupExists = try? await encryption.backupExistsOnServer()
                    logVerify("enableRecovery: backupExistsOnServer = \(String(describing: backupExists))")
                    if backupExists == true {
                        logVerify("enableRecovery: deleting orphaned backup via API")
                        await deleteBackupFromServer()
                    }
                }

                logVerify("enableRecovery: bootstrapping cross-signing from scratch")
                let progress = RecoveryProgressListener { state in
                    logVerify("Recovery progress: \(state)")
                }
                key = try await encryption.enableRecovery(
                    waitForBackupsToUpload: false,
                    passphrase: nil,
                    progressListener: progress
                )
            }
            logVerify("enableRecovery: done; key length=\(key.count) recoveryState=\(encryption.recoveryState())")
            return key
        } catch {
            logVerify("enableRecovery FAILED: \(error)")
            throw error
        }
    }

    // MARK: - Setup (controller + delegate)

    /// Sets up the verification controller and delegate. Call this
    /// once after sync starts so incoming requests are detected.
    ///
    /// `getSessionVerificationController()` internally calls
    /// `encryption().get_user_identity(userId)` without a server
    /// fallback. On a fresh login the cross-signing identity may
    /// not be in the local crypto store yet, causing "Failed
    /// retrieving user identity". We retry with back-off to give
    /// sync time to deliver the keys.
    func setup() async throws {
        guard !isControllerReady else { return }
        guard let client = matrixService.client else {
            throw VerificationError.clientNotAvailable
        }

        // `getSessionVerificationController()` calls
        // `get_user_identity(userId)` without server fallback.
        // On a fresh login the crypto store may be empty.
        // Pre-fetch the identity with server fallback to warm the store.
        let userId = try client.userId()
        let encryption = client.encryption()

        logVerify("setup: pre-fetching user identity for \(userId)")
        let identity = try? await encryption.userIdentity(userId: userId, fallbackToServer: true)
        logVerify("setup: userIdentity(fallbackToServer: true) = \(identity != nil ? "found" : "nil")")

        let controller = try await client.getSessionVerificationController()
        self.controller = controller

        let delegate = VerificationDelegate(
            onStep: { [weak self] step in
                DispatchQueue.main.async {
                    self?.stepSubject.send(step)
                }
            },
            onIncomingRequest: { [weak self] request in
                DispatchQueue.main.async {
                    self?.incomingRequestSubject.send(request)
                }
            },
            checkIsInitiator: { [weak self] in
                self?.isInitiator ?? false
            }
        )
        delegate.setController(controller)
        controller.setDelegate(delegate: delegate)
        self.delegate = delegate
        self.isControllerReady = true

        logVerify("Verification controller ready (persistent)")
    }

    // MARK: - Initiator Actions (this device requests verification)

    func requestDeviceVerification() async throws {
        guard let controller else { throw VerificationError.controllerNotReady }
        isInitiator = true
        stepSubject.send(.requestingVerification)

        // The SDK needs the user's cross-signing identity to be
        // downloaded before it can request verification. On a fresh
        // login the sync may not have delivered it yet, causing
        // "Failed retrieving user identity". Wait for verification
        // state to leave `.unknown`, then retry once on failure.
        await waitForIdentityReady(timeout: 10)

        do {
            try await controller.requestDeviceVerification()
            logVerify("Device verification requested")
        } catch {
            logVerify("requestDeviceVerification failed: \(error); retrying after 2s")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            try await controller.requestDeviceVerification()
            logVerify("Device verification requested (retry)")
        }
    }

    /// Waits for the SDK to know our verification state (i.e. it has
    /// downloaded the user's cross-signing identity from the server).
    /// `.unknown` means "still loading"; any other value means the
    /// identity is available.
    private func waitForIdentityReady(timeout: TimeInterval) async {
        let vSubject = matrixService.verificationStateSubject
        if vSubject.value != .unknown { return }

        logVerify("waitForIdentityReady: verificationState=\(vSubject.value), waiting…")
        let work = Task {
            for await state in vSubject.values {
                if state != .unknown {
                    logVerify("waitForIdentityReady: ready, verificationState=\(state)")
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
    }

    // MARK: - Responder Actions (another device requested verification)

    /// Acknowledge receipt of the incoming request (tells the SDK we saw it).
    func acknowledgeVerificationRequest(_ request: IncomingVerificationRequest) async throws {
        guard let controller else { throw VerificationError.controllerNotReady }
        try await controller.acknowledgeVerificationRequest(
            senderId: request.senderId,
            flowId: request.flowId
        )
        logVerify("Acknowledged verification request from \(request.deviceId)")
    }

    /// Accept the incoming verification request (user tapped Accept).
    func acceptVerificationRequest() async throws {
        guard let controller else { throw VerificationError.controllerNotReady }
        stepSubject.send(.acceptingRequest)
        try await controller.acceptVerificationRequest()
        logVerify("Accepted verification request")
    }

    // MARK: - Shared Actions

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

    /// Resets step back to initial for a new verification attempt.
    func resetStep() {
        stepSubject.send(.initial)
    }

    // MARK: - Private — Orphaned Backup Cleanup

    /// Deletes the key backup from the server via Matrix API.
    /// Used when a previous broken enableRecovery() left a backup
    /// without cross-signing keys, blocking a fresh bootstrap.
    private func deleteBackupFromServer() async {
        guard let client = matrixService.client,
              let session = try? client.session() else { return }

        var baseURL = session.homeserverUrl
        while baseURL.hasSuffix("/") { baseURL.removeLast() }

        // First get the current backup version
        guard let versionURL = URL(string: "\(baseURL)/_matrix/client/v3/room_keys/version") else { return }

        var versionReq = URLRequest(url: versionURL)
        versionReq.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: versionReq)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else {
                logVerify("deleteBackupFromServer: no backup version found")
                return
            }

            // Delete that version
            guard let deleteURL = URL(string: "\(baseURL)/_matrix/client/v3/room_keys/version/\(version)") else { return }
            var deleteReq = URLRequest(url: deleteURL)
            deleteReq.httpMethod = "DELETE"
            deleteReq.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

            let (_, resp) = try await URLSession.shared.data(for: deleteReq)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            logVerify("deleteBackupFromServer: deleted version \(version), HTTP \(code)")
        } catch {
            logVerify("deleteBackupFromServer: failed: \(error)")
        }
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
    private let onIncomingRequest: (IncomingVerificationRequest) -> Void
    private let checkIsInitiator: () -> Bool
    private var controller: SessionVerificationController?

    init(onStep: @escaping (VerificationStep) -> Void,
         onIncomingRequest: @escaping (IncomingVerificationRequest) -> Void,
         checkIsInitiator: @escaping () -> Bool) {
        self.onStep = onStep
        self.onIncomingRequest = onIncomingRequest
        self.checkIsInitiator = checkIsInitiator
    }

    func setController(_ controller: SessionVerificationController) {
        self.controller = controller
    }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        logVerify("Received verification request from device \(details.deviceId) (flow: \(details.flowId))")
        let request = IncomingVerificationRequest(
            senderId: details.senderProfile.userId,
            flowId: details.flowId,
            deviceId: details.deviceId,
            deviceDisplayName: details.deviceDisplayName
        )
        onIncomingRequest(request)
    }

    func didAcceptVerificationRequest() {
        logVerify("Verification request accepted (isInitiator=\(checkIsInitiator()))")
        onStep(.waitingForAcceptance)

        // Only the initiator starts SAS to avoid both sides racing.
        if checkIsInitiator() {
            Task {
                try? await controller?.startSasVerification()
            }
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
