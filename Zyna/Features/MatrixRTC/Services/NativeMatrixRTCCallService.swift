//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
import Foundation
import MatrixRTC
import MatrixRTCLiveKit
import MatrixRustSDK

private let log = ScopedLog(.call, prefix: "[matrixrtc-native]")

enum NativeMatrixRTCCallServiceState: Equatable {
    case idle
    case joining(roomId: String)
    case connected(roomId: String)
    case leaving(roomId: String)
}

enum NativeMatrixRTCCallPickupState: Equatable {
    case inactive
    case ringing(roomId: String, notificationEventId: String, expiresAt: Date)
    case answered(roomId: String)
    case declined(roomId: String)
    case timedOut(roomId: String)
}

enum NativeMatrixRTCCallServiceError: Error, Equatable {
    case alreadyActive(roomId: String)
    case missingMatrixClient
    case missingLiveKitTransport
    case noActiveCall
}

struct NativeMatrixRTCCallStartResult: Sendable {
    let roomId: String
    let ownMembership: MatrixRTCCallMembership
    let memberships: [MatrixRTCCallMembership]
    let keyShareResult: MatrixRTCMediaKeyShareResult
    let transport: MatrixRTCTransport
    let transportSource: MatrixRTCLiveKitTransportDiscoverySource
    let liveKitAlias: String
    let liveKitIdentity: String
}

final class NativeMatrixRTCCallService: @unchecked Sendable {
    static let shared = NativeMatrixRTCCallService()
    private static let audioCallIntent = "audio"
    private static let mediaKeyReshareDebounceNanoseconds: UInt64 = 150_000_000

    let stateSubject: CurrentValueSubject<NativeMatrixRTCCallServiceState, Never>
    let participantsSubject: CurrentValueSubject<NativeMatrixRTCCallParticipantsSnapshot, Never>
    let pickupStateSubject: CurrentValueSubject<NativeMatrixRTCCallPickupState, Never>

    var state: NativeMatrixRTCCallServiceState {
        withLock { serviceState }
    }

    private let lock = NSLock()
    private var serviceState: NativeMatrixRTCCallServiceState = .idle
    private var pickupState: NativeMatrixRTCCallPickupState = .inactive
    // Local generation id used to ignore stale events from canceled join attempts.
    private var currentCallAttemptID: UUID?
    private var activeCall: NativeMatrixRTCCall?
    private var membershipRefreshTask: Task<Void, Never>?
    private var mediaKeyReshareTask: Task<Void, Never>?
    private var pendingMediaKeyReshareReason: String?
    private var pickupTimeoutTask: Task<Void, Never>?
    private var pickupDeclineHandle: TaskHandle?
    private var autoLeaveWhenOthersLeftTask: Task<Void, Never>?
    private var participantStore = NativeMatrixRTCCallParticipantStore()
    private let subjectEmitter: NativeMatrixRTCCallSubjectEmitter
    private let audioSessionController = NativeMatrixRTCAudioSessionController.shared

    private init() {
        let stateSubject = CurrentValueSubject<NativeMatrixRTCCallServiceState, Never>(.idle)
        let participantsSubject = CurrentValueSubject<NativeMatrixRTCCallParticipantsSnapshot, Never>(.empty)
        let pickupStateSubject = CurrentValueSubject<NativeMatrixRTCCallPickupState, Never>(.inactive)

        self.stateSubject = stateSubject
        self.participantsSubject = participantsSubject
        self.pickupStateSubject = pickupStateSubject
        subjectEmitter = NativeMatrixRTCCallSubjectEmitter(
            stateSubject: stateSubject,
            participantsSubject: participantsSubject,
            pickupStateSubject: pickupStateSubject
        )
    }

    @discardableResult
    func startAudioCall(
        room: Room,
        fallbackLiveKitServiceURL: String? = nil,
        waitForPickup: Bool = false,
        autoLeaveWhenOthersLeft: Bool = false
    ) async throws -> NativeMatrixRTCCallStartResult {
        let roomId = room.id()
        let attemptID = try beginJoining(roomId: roomId)
        resetParticipantState(roomId: roomId)

        var matrixRTCSession: MatrixRTCSession?
        var liveKitSession: MatrixRTCLiveKitRoomSession?

        do {
            guard let client = MatrixClientService.shared.client else {
                throw NativeMatrixRTCCallServiceError.missingMatrixClient
            }
            try Task.checkCancellation()

            let focusClient = MatrixRustSDKRTCLiveKitFocusClient(client: client)
            guard let discoveredTransport = try await focusClient.discoverPreferredTransport(
                fallbackServiceURL: fallbackLiveKitServiceURL
            ) else {
                throw NativeMatrixRTCCallServiceError.missingLiveKitTransport
            }
            try Task.checkCancellation()

            let ownIdentity = try Self.legacyMembershipIdentity(client: client)
            let sfuConfig = try await focusClient.sfuConfig(
                for: ownIdentity,
                transport: discoveredTransport.transport,
                roomId: roomId,
                endpointVersion: .legacy
            )
            setLocalParticipantIdentity(sfuConfig.liveKitIdentity)
            try Task.checkCancellation()

            let liveKit = MatrixRTCLiveKitRoomSession(onEvent: { [weak self] event in
                log("LiveKit \(Self.liveKitEventDescription(event))")
                self?.handleLiveKitEvent(event, attemptID: attemptID)
                self?.handleLiveKitLifecycleEvent(event, attemptID: attemptID)
                if let reason = Self.mediaKeyReshareReason(for: event) {
                    self?.scheduleActiveMediaKeyReshare(reason: reason, attemptID: attemptID)
                }
                guard let reason = Self.membershipRefreshReason(for: event) else { return }
                self?.scheduleActiveMembershipRefresh(reason: reason, attemptID: attemptID)
            })
            liveKitSession = liveKit

            let toDeviceClient = MatrixRustSDKRTCToDeviceClient(client: client)
            let membershipClient = MatrixRustSDKRTCMembershipClient(client: client)
            let sessionMembershipClient = MatrixRustSDKRTCSessionMembershipClient(
                membershipClient: membershipClient,
                room: room
            )

            let session = MatrixRTCSession(
                configuration: .init(
                    ownMembershipIdentity: ownIdentity,
                    focusSelection: .oldestMembership,
                    fociPreferred: [discoveredTransport.transport],
                    callIntent: Self.audioCallIntent
                ),
                membershipClient: sessionMembershipClient,
                keyTransportFactory: { identity in
                    MatrixRTCToDeviceKeyTransport(
                        roomId: roomId,
                        ownIdentity: identity,
                        client: toDeviceClient
                    )
                },
                onKeyChanged: liveKit.keyChangedHandler { error in
                    log("Failed to apply media key: \(error)")
                },
                onError: { error in
                    log("MatrixRTC session error: \(error)")
                }
            )
            matrixRTCSession = session

            let joinResult = try await session.join()
            try Task.checkCancellation()
            let callNotification = await sendCallNotificationIfNeeded(
                room: room,
                joinResult: joinResult,
                waitForPickup: waitForPickup
            )
            try Task.checkCancellation()
            try audioSessionController.configureForCall()
            try Task.checkCancellation()
            try await liveKit.connect(sfuConfig: sfuConfig, publishAudio: true)
            try Task.checkCancellation()

            let call = NativeMatrixRTCCall(
                attemptID: attemptID,
                roomId: roomId,
                ownUserId: ownIdentity.userId,
                matrixRTCSession: session,
                liveKitSession: liveKit,
                discoveredTransport: discoveredTransport,
                sfuConfig: sfuConfig,
                autoLeaveWhenOthersLeft: autoLeaveWhenOthersLeft,
                pickupAttempt: Self.pickupAttempt(
                    from: callNotification,
                    waitForPickup: waitForPickup
                )
            )
            guard finishJoined(call) else {
                liveKitSession = nil
                matrixRTCSession = nil
                await liveKit.disconnect()
                _ = try? await session.leave()
                audioSessionController.deactivateAfterCall()
                log("Ignored stale MatrixRTC join completion in room \(roomId)")
                throw CancellationError()
            }

            startCallPickupLifecycleIfNeeded(room: room, call: call)
            log("Joined native MatrixRTC audio call in room \(roomId)")
            return .init(
                roomId: roomId,
                ownMembership: joinResult.ownMembership,
                memberships: joinResult.memberships,
                keyShareResult: joinResult.keyShareResult,
                transport: discoveredTransport.transport,
                transportSource: discoveredTransport.source,
                liveKitAlias: sfuConfig.liveKitAlias,
                liveKitIdentity: sfuConfig.liveKitIdentity
            )
        } catch {
            log("Failed to join native MatrixRTC audio call in room \(roomId): \(error)")
            if let liveKitSession, liveKitSession.state != .idle {
                await liveKitSession.disconnect()
            }
            if let matrixRTCSession {
                _ = try? await matrixRTCSession.leave()
            }
            audioSessionController.deactivateAfterCall()
            finishFailed(attemptID: attemptID)
            throw error
        }
    }

    @discardableResult
    func refreshActiveMemberships() async throws -> MatrixRTCSessionMembershipRefreshResult {
        guard let activeCall = currentActiveCall() else {
            throw NativeMatrixRTCCallServiceError.noActiveCall
        }

        return try await activeCall.matrixRTCSession.refreshMemberships()
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let activeCall = currentActiveCall() else {
            throw NativeMatrixRTCCallServiceError.noActiveCall
        }

        try await activeCall.liveKitSession.setMicrophoneEnabled(enabled)
    }

    func setCameraEnabled(_ enabled: Bool) async throws {
        guard let activeCall = currentActiveCall() else {
            throw NativeMatrixRTCCallServiceError.noActiveCall
        }

        try await activeCall.liveKitSession.setCameraEnabled(enabled)
    }

    func switchCameraPosition() async throws {
        guard let activeCall = currentActiveCall() else {
            throw NativeMatrixRTCCallServiceError.noActiveCall
        }

        _ = try await activeCall.liveKitSession.switchCameraPosition()
    }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        guard currentActiveCall() != nil else {
            throw NativeMatrixRTCCallServiceError.noActiveCall
        }

        try audioSessionController.setSpeakerEnabled(enabled)
    }

    var isSpeakerEnabled: Bool {
        audioSessionController.isSpeakerEnabled
    }

    func leaveActiveCall() async throws {
        _ = try await leaveActiveCall(reason: "user")
    }

    @discardableResult
    func endActiveCall(reason: String) async -> Bool {
        do {
            return try await leaveActiveCall(reason: reason)
        } catch {
            log("Failed ending native MatrixRTC call reason=\(reason): \(error)")
            return false
        }
    }
}

private extension NativeMatrixRTCCallService {
    func handleLiveKitLifecycleEvent(_ event: MatrixRTCLiveKitRoomSessionEvent, attemptID: UUID) {
        switch event {
        case .disconnected(let error):
            scheduleActiveCallEnd(reason: "liveKitDisconnected(\(error ?? "nil"))", attemptID: attemptID)
        case .failedToConnect(let error):
            scheduleActiveCallEnd(reason: "liveKitFailedToConnect(\(error ?? "nil"))", attemptID: attemptID)
        default:
            break
        }
    }

    func scheduleActiveCallEnd(reason: String, attemptID: UUID) {
        guard shouldEndActiveCallForLifecycleEvent(attemptID: attemptID) else { return }

        Task { [weak self] in
            guard let self else { return }
            await self.endActiveCall(reason: reason, attemptID: attemptID)
        }
    }

    func shouldEndActiveCallForLifecycleEvent(attemptID: UUID) -> Bool {
        withLock {
            guard activeCall?.attemptID == attemptID else { return false }
            switch serviceState {
            case .connected:
                return true
            case .idle, .joining, .leaving:
                return false
            }
        }
    }

    @discardableResult
    func endActiveCall(reason: String, attemptID: UUID) async -> Bool {
        do {
            return try await leaveActiveCall(reason: reason, attemptID: attemptID)
        } catch {
            log("Failed ending native MatrixRTC call reason=\(reason): \(error)")
            return false
        }
    }

    @discardableResult
    func leaveActiveCall(reason: String) async throws -> Bool {
        guard let call = beginLeaving(reason: reason) else {
            return false
        }

        return try await leave(call: call, reason: reason)
    }

    @discardableResult
    func leaveActiveCall(reason: String, attemptID: UUID) async throws -> Bool {
        guard let call = beginLeaving(reason: reason, attemptID: attemptID) else {
            return false
        }

        return try await leave(call: call, reason: reason)
    }

    @discardableResult
    func leave(call: NativeMatrixRTCCall, reason: String) async throws -> Bool {
        await call.liveKitSession.disconnect()
        defer {
            audioSessionController.deactivateAfterCall()
            finishLeft(attemptID: call.attemptID)
        }

        _ = try await call.matrixRTCSession.leave()
        log("Left native MatrixRTC call in room \(call.roomId) reason=\(reason)")
        return true
    }

    func beginJoining(roomId: String) throws -> UUID {
        let nextState = NativeMatrixRTCCallServiceState.joining(roomId: roomId)
        let attemptID = try withLock {
            if let activeCall {
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: activeCall.roomId)
            }

            if currentCallAttemptID != nil {
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: serviceState.roomId ?? roomId)
            }

            switch serviceState {
            case .idle:
                let attemptID = UUID()
                currentCallAttemptID = attemptID
                serviceState = nextState
                subjectEmitter.enqueue(.state(nextState))
                return attemptID
            case .joining(let roomId), .connected(let roomId), .leaving(let roomId):
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: roomId)
            }
        }
        return attemptID
    }

    func finishJoined(_ call: NativeMatrixRTCCall) -> Bool {
        let nextState = NativeMatrixRTCCallServiceState.connected(roomId: call.roomId)
        let joined = withLock {
            guard currentCallAttemptID == call.attemptID else { return false }
            guard case .joining = serviceState else { return false }
            activeCall = call
            serviceState = nextState
            subjectEmitter.enqueue(.state(nextState))
            return true
        }
        return joined
    }

    func finishFailed(attemptID: UUID) {
        let tasksToCancel: NativeMatrixRTCCallTasksToCancel? = withLock {
            guard currentCallAttemptID == attemptID else { return nil }
            let tasksToCancel = takeCallTasksLocked()
            currentCallAttemptID = nil
            activeCall = nil
            serviceState = .idle
            pickupState = .inactive
            let snapshot = participantStore.reset(roomId: nil)
            subjectEmitter.enqueue([
                .state(serviceState),
                .pickupState(pickupState),
                .participants(snapshot)
            ])
            return tasksToCancel
        }
        tasksToCancel?.cancel()
    }

    func beginLeaving(reason: String) -> NativeMatrixRTCCall? {
        beginLeaving(reason: reason, attemptID: nil)
    }

    func beginLeaving(reason: String, attemptID: UUID?) -> NativeMatrixRTCCall? {
        let result: (
            call: NativeMatrixRTCCall?,
            logRoomId: String?,
            tasksToCancel: NativeMatrixRTCCallTasksToCancel
        ) = withLock {
            if let attemptID, currentCallAttemptID != attemptID {
                return (call: nil, logRoomId: nil, tasksToCancel: .empty)
            }

            guard let activeCall else {
                guard currentCallAttemptID != nil else {
                    serviceState = .idle
                    subjectEmitter.enqueue(.state(serviceState))
                    return (call: nil, logRoomId: nil, tasksToCancel: .empty)
                }

                switch serviceState {
                case .joining(let roomId):
                    let tasksToCancel = takeCallTasksLocked()
                    serviceState = .leaving(roomId: roomId)
                    subjectEmitter.enqueue(.state(serviceState))
                    return (call: nil, logRoomId: roomId, tasksToCancel: tasksToCancel)
                case .idle:
                    serviceState = .idle
                    subjectEmitter.enqueue(.state(serviceState))
                    return (call: nil, logRoomId: nil, tasksToCancel: .empty)
                case .connected(let roomId), .leaving(let roomId):
                    serviceState = .leaving(roomId: roomId)
                    subjectEmitter.enqueue(.state(serviceState))
                    return (call: nil, logRoomId: nil, tasksToCancel: .empty)
                }
            }

            switch serviceState {
            case .leaving:
                return (call: nil, logRoomId: nil, tasksToCancel: .empty)
            case .idle, .joining, .connected:
                let tasksToCancel = takeCallTasksLocked()
                serviceState = .leaving(roomId: activeCall.roomId)
                subjectEmitter.enqueue(.state(serviceState))
                return (
                    call: activeCall,
                    logRoomId: activeCall.roomId,
                    tasksToCancel: tasksToCancel
                )
            }
        }

        result.tasksToCancel.cancel()
        if let roomId = result.logRoomId {
            log("Ending native MatrixRTC call in room \(roomId) reason=\(reason)")
        }
        return result.call
    }

    func finishLeft(attemptID: UUID) {
        let tasksToCancel: NativeMatrixRTCCallTasksToCancel? = withLock {
            guard currentCallAttemptID == attemptID else { return nil }
            let tasksToCancel = takeCallTasksLocked()
            currentCallAttemptID = nil
            activeCall = nil
            serviceState = .idle
            pickupState = .inactive
            let snapshot = participantStore.reset(roomId: nil)
            subjectEmitter.enqueue([
                .state(serviceState),
                .pickupState(pickupState),
                .participants(snapshot)
            ])
            return tasksToCancel
        }
        tasksToCancel?.cancel()
    }

    func currentActiveCall() -> NativeMatrixRTCCall? {
        withLock { activeCall }
    }

    func resetParticipantState(roomId: String?) {
        withLock {
            let snapshot = participantStore.reset(roomId: roomId)
            subjectEmitter.enqueue(.participants(snapshot))
        }
    }

    func setLocalParticipantIdentity(_ identity: String?) {
        withLock {
            let snapshot = participantStore.setLocalIdentity(identity)
            subjectEmitter.enqueue(.participants(snapshot))
        }
    }

    func handleLiveKitEvent(_ event: MatrixRTCLiveKitRoomSessionEvent, attemptID: UUID) {
        let result: (
            shouldCheckAutoLeave: Bool,
            shouldCancelAutoLeaveCheck: Bool
        )? = withLock {
            guard currentCallAttemptID == attemptID else { return nil }
            guard participantStore.snapshot.roomId != nil else { return nil }
            let previousRemoteParticipantCount = participantStore.snapshot.remoteParticipantCount
            guard let snapshot = participantStore.apply(event) else { return nil }
            subjectEmitter.enqueue(.participants(snapshot))
            let shouldCheckAutoLeave = activeCall?.attemptID == attemptID
                && activeCall?.autoLeaveWhenOthersLeft == true
                && previousRemoteParticipantCount > 0
                && snapshot.remoteParticipantCount == 0
            let shouldCancelAutoLeaveCheck = activeCall?.attemptID == attemptID
                && activeCall?.autoLeaveWhenOthersLeft == true
                && snapshot.remoteParticipantCount > 0
            return (
                shouldCheckAutoLeave: shouldCheckAutoLeave,
                shouldCancelAutoLeaveCheck: shouldCancelAutoLeaveCheck
            )
        }
        guard let result else { return }

        if result.shouldCancelAutoLeaveCheck {
            cancelAutoLeaveWhenOthersLeftCheck()
        }

        guard result.shouldCheckAutoLeave else { return }
        scheduleAutoLeaveWhenOthersLeftCheck(attemptID: attemptID)
    }

    func scheduleAutoLeaveWhenOthersLeftCheck(attemptID: UUID) {
        let call = withLock { activeCall?.attemptID == attemptID ? activeCall : nil }
        guard let call, call.autoLeaveWhenOthersLeft else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.autoLeaveWhenOthersLeftIfConfirmed(call: call)
        }

        let taskToCancel: Task<Void, Never>? = withLock {
            guard activeCall?.attemptID == attemptID else {
                return task
            }
            let previousTask = autoLeaveWhenOthersLeftTask
            autoLeaveWhenOthersLeftTask = task
            return previousTask
        }
        taskToCancel?.cancel()
    }

    func autoLeaveWhenOthersLeftIfConfirmed(call: NativeMatrixRTCCall) async {
        let delaysNanoseconds: [UInt64] = [
            800_000_000,
            1_200_000_000,
            2_000_000_000,
            4_000_000_000,
            8_000_000_000,
            8_000_000_000
        ]

        for attemptIndex in delaysNanoseconds.indices {
            guard isAutoLeaveWhenOthersLeftCheckNeeded(call: call) else { return }

            do {
                try await Task.sleep(nanoseconds: delaysNanoseconds[attemptIndex])
            } catch {
                return
            }

            guard isAutoLeaveWhenOthersLeftCheckNeeded(call: call) else { return }

            do {
                let result = try await call.matrixRTCSession.refreshMemberships(distributeKeys: false)
                guard isAutoLeaveWhenOthersLeftCheckNeeded(call: call) else { return }
                if !Self.containsRemoteMembership(result.memberships, ownUserId: call.ownUserId) {
                    log("Confirmed MatrixRTC DM all others left memberships=\(result.memberships.count)")
                    await endActiveCall(reason: "allOthersLeft", attemptID: call.attemptID)
                    return
                }

                log("MatrixRTC DM remote membership still active after LiveKit leave attempt=\(attemptIndex + 1)")
            } catch {
                guard !Task.isCancelled else { return }
                log("Failed checking MatrixRTC DM all-others-left attempt=\(attemptIndex + 1): \(error)")
            }
        }

        log("Skipped MatrixRTC DM auto-leave: remote membership stayed active")
    }

    func isAutoLeaveWhenOthersLeftCheckNeeded(call: NativeMatrixRTCCall) -> Bool {
        withLock {
            activeCall?.attemptID == call.attemptID
                && activeCall?.autoLeaveWhenOthersLeft == true
                && participantStore.snapshot.remoteParticipantCount == 0
        }
    }

    func cancelAutoLeaveWhenOthersLeftCheck() {
        let task = withLock {
            let task = autoLeaveWhenOthersLeftTask
            autoLeaveWhenOthersLeftTask = nil
            return task
        }
        task?.cancel()
    }

    func startCallPickupLifecycleIfNeeded(room: Room, call: NativeMatrixRTCCall) {
        guard let pickupAttempt = call.pickupAttempt else {
            return
        }

        let remainingNanoseconds = Self.remainingNanoseconds(until: pickupAttempt.expiresAt)
        guard remainingNanoseconds > 0 else {
            let nextPickupState = NativeMatrixRTCCallPickupState.ringing(
                roomId: call.roomId,
                notificationEventId: pickupAttempt.notificationEventId,
                expiresAt: pickupAttempt.expiresAt
            )
            let started = withLock {
                guard activeCall?.attemptID == call.attemptID else { return false }
                pickupState = nextPickupState
                subjectEmitter.enqueue(.pickupState(nextPickupState))
                return true
            }
            guard started else { return }
            Task { [weak self] in
                await self?.handleCallPickupTimeout(
                    attemptID: call.attemptID,
                    notificationEventId: pickupAttempt.notificationEventId
                )
            }
            return
        }

        let timeoutTask = callPickupTimeoutTask(call: call, pickupAttempt: pickupAttempt)
        var declineHandle: TaskHandle?
        do {
            let declineListener = NativeMatrixRTCCallDeclineListener { [weak self] declinerUserId in
                self?.handleCallPickupDecline(
                    attemptID: call.attemptID,
                    notificationEventId: pickupAttempt.notificationEventId,
                    declinerUserId: declinerUserId
                )
            }
            declineHandle = try room.subscribeToCallDeclineEvents(
                rtcNotificationEventId: pickupAttempt.notificationEventId,
                listener: declineListener
            )
        } catch {
            log("Failed observing MatrixRTC pickup decline room=\(call.roomId) notificationEventId=\(pickupAttempt.notificationEventId): \(error)")
        }

        let nextPickupState = NativeMatrixRTCCallPickupState.ringing(
            roomId: call.roomId,
            notificationEventId: pickupAttempt.notificationEventId,
            expiresAt: pickupAttempt.expiresAt
        )
        let startResult: (
            previousDeclineHandle: TaskHandle?,
            previousTimeoutTask: Task<Void, Never>?
        )? = withLock {
            guard activeCall?.attemptID == call.attemptID else { return nil }
            let previousDeclineHandle = pickupDeclineHandle
            let previousTimeoutTask = pickupTimeoutTask
            pickupDeclineHandle = declineHandle
            pickupTimeoutTask = timeoutTask
            pickupState = nextPickupState
            subjectEmitter.enqueue(.pickupState(nextPickupState))
            return (
                previousDeclineHandle: previousDeclineHandle,
                previousTimeoutTask: previousTimeoutTask
            )
        }

        if let startResult {
            startResult.previousDeclineHandle?.cancel()
            startResult.previousTimeoutTask?.cancel()
            log("Started MatrixRTC pickup wait room=\(call.roomId) notificationEventId=\(pickupAttempt.notificationEventId) timeoutMs=\(pickupAttempt.lifetimeMilliseconds)")
        } else {
            declineHandle?.cancel()
            timeoutTask.cancel()
        }
    }

    func handleCallPickupDecline(
        attemptID: UUID,
        notificationEventId: String,
        declinerUserId: String
    ) {
        let result: (
            timeoutTask: Task<Void, Never>?,
            declineHandle: TaskHandle?
        )? = withLock {
            guard let activeCall,
                  activeCall.attemptID == attemptID,
                  activeCall.pickupAttempt?.notificationEventId == notificationEventId,
                  declinerUserId != activeCall.ownUserId,
                  pickupState.isRinging else {
                return nil
            }

            let timeoutTask = pickupTimeoutTask
            let declineHandle = pickupDeclineHandle
            pickupTimeoutTask = nil
            pickupDeclineHandle = nil
            pickupState = .declined(roomId: activeCall.roomId)
            subjectEmitter.enqueue(.pickupState(pickupState))
            return (
                timeoutTask: timeoutTask,
                declineHandle: declineHandle
            )
        }

        guard let result else { return }
        result.timeoutTask?.cancel()
        result.declineHandle?.cancel()
        log("MatrixRTC pickup declined notificationEventId=\(notificationEventId) sender=\(declinerUserId)")
        Task { [weak self] in
            await self?.endActiveCall(reason: "pickupDeclined", attemptID: attemptID)
        }
    }

    func handleCallPickupTimeout(
        attemptID: UUID,
        notificationEventId: String
    ) async {
        let result: (
            declineHandle: TaskHandle?,
            roomId: String
        )? = withLock {
            guard let activeCall,
                  activeCall.attemptID == attemptID,
                  activeCall.pickupAttempt?.notificationEventId == notificationEventId,
                  pickupState.isRinging else {
                return nil
            }

            pickupTimeoutTask = nil
            let declineHandle = pickupDeclineHandle
            pickupDeclineHandle = nil
            pickupState = .timedOut(roomId: activeCall.roomId)
            subjectEmitter.enqueue(.pickupState(pickupState))
            return (declineHandle: declineHandle, roomId: activeCall.roomId)
        }

        guard let result else { return }
        result.declineHandle?.cancel()
        log("MatrixRTC pickup timed out room=\(result.roomId) notificationEventId=\(notificationEventId)")
        await endActiveCall(reason: "pickupTimeout", attemptID: attemptID)
    }

    func callPickupTimeoutTask(
        call: NativeMatrixRTCCall,
        pickupAttempt: NativeMatrixRTCCallPickupAttempt
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                let remainingNanoseconds = Self.remainingNanoseconds(until: pickupAttempt.expiresAt)
                guard remainingNanoseconds > 0 else {
                    await self?.handleCallPickupTimeout(
                        attemptID: call.attemptID,
                        notificationEventId: pickupAttempt.notificationEventId
                    )
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: min(remainingNanoseconds, 1_000_000_000))
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                if await self?.refreshCallPickupMemberships(
                    call: call,
                    notificationEventId: pickupAttempt.notificationEventId
                ) == true {
                    return
                }
            }
        }
    }

    func refreshCallPickupMemberships(
        call: NativeMatrixRTCCall,
        notificationEventId: String
    ) async -> Bool {
        guard isActiveRingingPickup(
            attemptID: call.attemptID,
            notificationEventId: notificationEventId
        ) else {
            return true
        }

        do {
            let result = try await call.matrixRTCSession.refreshMemberships(distributeKeys: false)
            handleMembershipRefreshForPickup(call: call, memberships: result.memberships)
        } catch {
            guard !Task.isCancelled else { return true }
            log("Failed refreshing MatrixRTC pickup memberships notificationEventId=\(notificationEventId): \(error)")
        }

        return !isActiveRingingPickup(
            attemptID: call.attemptID,
            notificationEventId: notificationEventId
        )
    }

    func isActiveRingingPickup(attemptID: UUID, notificationEventId: String) -> Bool {
        withLock {
            guard let activeCall,
                  activeCall.attemptID == attemptID,
                  activeCall.pickupAttempt?.notificationEventId == notificationEventId,
                  pickupState.isRinging else {
                return false
            }
            return true
        }
    }

    func handleMembershipRefreshForPickup(
        call: NativeMatrixRTCCall,
        memberships: [MatrixRTCCallMembership]
    ) {
        guard memberships.contains(where: { $0.userId != call.ownUserId }) else {
            return
        }

        let result: (
            timeoutTask: Task<Void, Never>?,
            declineHandle: TaskHandle?
        )? = withLock {
            guard activeCall?.attemptID == call.attemptID,
                  call.pickupAttempt != nil,
                  pickupState.isRinging else {
                return nil
            }

            let timeoutTask = pickupTimeoutTask
            let declineHandle = pickupDeclineHandle
            pickupTimeoutTask = nil
            pickupDeclineHandle = nil
            pickupState = .answered(roomId: call.roomId)
            subjectEmitter.enqueue(.pickupState(pickupState))
            return (
                timeoutTask: timeoutTask,
                declineHandle: declineHandle
            )
        }

        guard let result else { return }
        result.timeoutTask?.cancel()
        result.declineHandle?.cancel()
        log("MatrixRTC pickup answered room=\(call.roomId)")
    }

    func sendCallNotificationIfNeeded(
        room: Room,
        joinResult: MatrixRTCSessionJoinResult,
        waitForPickup: Bool
    ) async -> MatrixRTCCallNotificationSendResult? {
        guard Self.shouldSendCallNotification(
            ownMembership: joinResult.ownMembership,
            memberships: joinResult.memberships
        ) else {
            return nil
        }

        let notificationType: MatrixRTCCallNotificationType = waitForPickup ? .ring : .notification
        do {
            let result = try await MatrixRustSDKRTCCallNotificationClient(room: room).sendCallNotification(
                parentEventId: joinResult.ownMembership.eventId,
                slot: joinResult.ownMembership.slot,
                notificationType: notificationType,
                callIntent: Self.audioCallIntent
            )
            log("Sent MatrixRTC call notification for room \(room.id()) parent=\(joinResult.ownMembership.eventId) type=\(result.notificationType.rawValue) notification=\(result.sentNotification) notificationEventId=\(result.notificationEventId ?? "nil") legacy=\(result.sentLegacyFallback) legacyEventId=\(result.legacyFallbackEventId ?? "nil") legacyCallId=\(joinResult.ownMembership.slot.id)")
            return result
        } catch {
            log("Failed sending MatrixRTC call notification for room \(room.id()): \(error)")
            return nil
        }
    }

    func scheduleActiveMediaKeyReshare(reason: String, attemptID: UUID) {
        let callToStart: NativeMatrixRTCCall? = withLock {
            guard let call = activeCall,
                  call.attemptID == attemptID else {
                return nil
            }

            pendingMediaKeyReshareReason = Self.coalescedMediaKeyReshareReason(
                pendingMediaKeyReshareReason,
                reason
            )
            guard mediaKeyReshareTask == nil else {
                return nil
            }
            return call
        }
        guard let callToStart else { return }

        let reshareTask = Task { [weak self] in
            guard let self else { return }
            await self.runCoalescedMediaKeyReshares(call: callToStart)
        }

        let taskToCancel: Task<Void, Never>? = withLock {
            guard activeCall?.attemptID == attemptID,
                  mediaKeyReshareTask == nil else {
                return reshareTask
            }
            mediaKeyReshareTask = reshareTask
            return nil
        }
        taskToCancel?.cancel()
    }

    func runCoalescedMediaKeyReshares(call: NativeMatrixRTCCall) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.mediaKeyReshareDebounceNanoseconds)
            } catch {
                return
            }

            guard let reason = takePendingMediaKeyReshareReason(call: call) else {
                if completeMediaKeyReshareTaskIfIdle(call: call) {
                    return
                }
                continue
            }

            await reshareActiveMediaKey(call: call, reason: reason)
        }
    }

    func reshareActiveMediaKey(
        call: NativeMatrixRTCCall,
        reason: String
    ) async {
        let delaysNanoseconds: [UInt64] = [
            0,
            1_000_000_000,
            2_000_000_000
        ]

        for attemptIndex in delaysNanoseconds.indices {
            let delay = delaysNanoseconds[attemptIndex]
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            guard currentActiveCall()?.attemptID == call.attemptID else { return }

            do {
                let result = try await call.matrixRTCSession.reshareCurrentMediaKey()
                let sharedCount = result.keyShareResult.sharedWith.count
                let failureCount = result.keyShareResult.failures.count
                log(
                    "Reshared MatrixRTC media key reason=\(reason) attempt=\(attemptIndex + 1) memberships=\(result.memberships.count) sharedKeys=\(sharedCount) failures=\(failureCount)"
                )
                handleMembershipRefreshForPickup(call: call, memberships: result.memberships)

                if sharedCount > 0, failureCount == 0 {
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                log(
                    "Failed resharing MatrixRTC media key reason=\(reason) attempt=\(attemptIndex + 1): \(error)"
                )
            }
        }
    }

    func scheduleActiveMembershipRefresh(reason: String, attemptID: UUID) {
        let call = withLock { activeCall?.attemptID == attemptID ? activeCall : nil }
        guard let call else { return }

        let refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshActiveMembershipsAfterRemoteJoin(
                call: call,
                reason: reason
            )
        }

        let taskToCancel: Task<Void, Never>? = withLock {
            guard activeCall?.attemptID == attemptID else {
                return refreshTask
            }
            let previousTask = membershipRefreshTask
            membershipRefreshTask = refreshTask
            return previousTask
        }
        taskToCancel?.cancel()
    }

    func refreshActiveMembershipsAfterRemoteJoin(
        call: NativeMatrixRTCCall,
        reason: String
    ) async {
        let delaysNanoseconds: [UInt64] = [
            0,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000
        ]

        for attemptIndex in delaysNanoseconds.indices {
            let delay = delaysNanoseconds[attemptIndex]
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            guard currentActiveCall()?.attemptID == call.attemptID else { return }

            do {
                let result = try await call.matrixRTCSession.refreshMemberships()
                let sharedCount = result.keyShareResult.sharedWith.count
                let failureCount = result.keyShareResult.failures.count
                log(
                    "Refreshed MatrixRTC memberships reason=\(reason) attempt=\(attemptIndex + 1) memberships=\(result.memberships.count) sharedKeys=\(sharedCount) failures=\(failureCount)"
                )
                handleMembershipRefreshForPickup(call: call, memberships: result.memberships)

                if sharedCount > 0, failureCount == 0 {
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                log(
                    "Failed refreshing MatrixRTC memberships reason=\(reason) attempt=\(attemptIndex + 1): \(error)"
                )
            }
        }
    }

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    // Must be called while holding lock.
    func takeCallTasksLocked() -> NativeMatrixRTCCallTasksToCancel {
        let tasks = NativeMatrixRTCCallTasksToCancel(
            membershipRefreshTask: membershipRefreshTask,
            mediaKeyReshareTask: mediaKeyReshareTask,
            pickupTimeoutTask: pickupTimeoutTask,
            pickupDeclineHandle: pickupDeclineHandle,
            autoLeaveWhenOthersLeftTask: autoLeaveWhenOthersLeftTask
        )
        membershipRefreshTask = nil
        mediaKeyReshareTask = nil
        pendingMediaKeyReshareReason = nil
        pickupTimeoutTask = nil
        pickupDeclineHandle = nil
        autoLeaveWhenOthersLeftTask = nil
        return tasks
    }

    static func legacyMembershipIdentity(client: Client) throws -> MatrixRTCMembershipIdentity {
        let userId = try client.userId()
        let deviceId = try client.deviceId()
        let memberId = MatrixRTCMembershipIdentity.legacyRTCBackendIdentity(
            userId: userId,
            deviceId: deviceId
        )
        return .init(userId: userId, deviceId: deviceId, memberId: memberId)
    }

    static func shouldSendCallNotification(
        ownMembership: MatrixRTCCallMembership,
        memberships: [MatrixRTCCallMembership]
    ) -> Bool {
        !memberships.contains { membership in
            membership.userId != ownMembership.userId
                || membership.deviceId != ownMembership.deviceId
                || membership.memberId != ownMembership.memberId
        }
    }

    static func containsRemoteMembership(
        _ memberships: [MatrixRTCCallMembership],
        ownUserId: String
    ) -> Bool {
        memberships.contains { $0.userId != ownUserId }
    }

    static func pickupAttempt(
        from notification: MatrixRTCCallNotificationSendResult?,
        waitForPickup: Bool
    ) -> NativeMatrixRTCCallPickupAttempt? {
        guard waitForPickup,
              let notification,
              notification.sentNotification,
              notification.notificationType == .ring,
              let notificationEventId = notification.notificationEventId else {
            return nil
        }

        let expiresAt = Date(
            timeIntervalSince1970: TimeInterval(
                notification.senderTimestamp + notification.lifetimeMilliseconds
            ) / 1000
        )
        return NativeMatrixRTCCallPickupAttempt(
            notificationEventId: notificationEventId,
            expiresAt: expiresAt,
            lifetimeMilliseconds: notification.lifetimeMilliseconds
        )
    }

    static func remainingNanoseconds(until date: Date) -> UInt64 {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }

    func takePendingMediaKeyReshareReason(call: NativeMatrixRTCCall) -> String? {
        withLock {
            guard activeCall?.attemptID == call.attemptID else {
                pendingMediaKeyReshareReason = nil
                return nil
            }

            let reason = pendingMediaKeyReshareReason
            pendingMediaKeyReshareReason = nil
            return reason
        }
    }

    func completeMediaKeyReshareTaskIfIdle(call: NativeMatrixRTCCall) -> Bool {
        withLock {
            guard activeCall?.attemptID == call.attemptID else {
                mediaKeyReshareTask = nil
                pendingMediaKeyReshareReason = nil
                return true
            }

            guard pendingMediaKeyReshareReason == nil else {
                return false
            }

            mediaKeyReshareTask = nil
            return true
        }
    }

    static func coalescedMediaKeyReshareReason(_ current: String?, _ next: String) -> String {
        guard let current else { return next }
        return current == next ? current : "coalesced"
    }

    static func mediaKeyReshareReason(for event: MatrixRTCLiveKitRoomSessionEvent) -> String? {
        switch event {
        case .localTrackSubscribedByRemote:
            return "localTrackSubscribedByRemote"
        default:
            return nil
        }
    }

    static func membershipRefreshReason(for event: MatrixRTCLiveKitRoomSessionEvent) -> String? {
        switch event {
        case .remoteParticipantJoined:
            return "remoteParticipantJoined"
        case .remoteTrackPublished:
            return "remoteTrackPublished"
        case .remoteTrackSubscribed:
            return "remoteTrackSubscribed"
        case .remoteVideoTrackSubscribed:
            return "remoteVideoTrackSubscribed"
        default:
            return nil
        }
    }

    static func liveKitEventDescription(_ event: MatrixRTCLiveKitRoomSessionEvent) -> String {
        switch event {
        case .connectionStateChanged(let state, let previousState):
            return "connectionState \(previousState) -> \(state)"
        case .connected:
            return "connected"
        case .disconnected(let error):
            return "disconnected error=\(error ?? "nil")"
        case .failedToConnect(let error):
            return "failedToConnect error=\(error ?? "nil")"
        case .localTrackPublished(let publication):
            return "localTrackPublished \(trackDescription(publication))"
        case .localTrackUnpublished(let publication):
            return "localTrackUnpublished \(trackDescription(publication))"
        case .localVideoTrackPublished(let publication, let videoTrack):
            return "localVideoTrackPublished \(trackDescription(publication)) videoTrack=\(videoTrack.id)"
        case .localVideoTrackUnpublished(let publication):
            return "localVideoTrackUnpublished \(trackDescription(publication))"
        case .localTrackSubscribedByRemote(let publication):
            return "localTrackSubscribedByRemote \(trackDescription(publication))"
        case .remoteParticipantJoined(let participant):
            return "remoteParticipantJoined \(participantDescription(participant))"
        case .remoteParticipantLeft(let participant):
            return "remoteParticipantLeft \(participantDescription(participant))"
        case .remoteTrackPublished(let participant, let publication):
            return "remoteTrackPublished participant=\(participantDescription(participant)) \(trackDescription(publication))"
        case .remoteTrackUnpublished(let participant, let publication):
            return "remoteTrackUnpublished participant=\(participantDescription(participant)) \(trackDescription(publication))"
        case .remoteTrackSubscribed(let participant, let publication):
            return "remoteTrackSubscribed participant=\(participantDescription(participant)) \(trackDescription(publication))"
        case .remoteTrackUnsubscribed(let participant, let publication):
            return "remoteTrackUnsubscribed participant=\(participantDescription(participant)) \(trackDescription(publication))"
        case .remoteVideoTrackSubscribed(let participant, let publication, let videoTrack):
            return "remoteVideoTrackSubscribed participant=\(participantDescription(participant)) \(trackDescription(publication)) videoTrack=\(videoTrack.id)"
        case .remoteVideoTrackUnsubscribed(let participant, let publication):
            return "remoteVideoTrackUnsubscribed participant=\(participantDescription(participant)) \(trackDescription(publication))"
        case .remoteTrackSubscriptionFailed(let participant, let trackSid, let error):
            return "remoteTrackSubscriptionFailed participant=\(participantDescription(participant)) sid=\(trackSid) error=\(error)"
        case .trackMutedChanged(let participant, let publication, let isMuted):
            return "trackMutedChanged participant=\(participantDescription(participant)) \(trackDescription(publication)) muted=\(isMuted)"
        case .remoteTrackStreamStateChanged(let participant, let publication, let state):
            return "remoteTrackStreamStateChanged participant=\(participantDescription(participant)) \(trackDescription(publication)) state=\(state)"
        case .trackE2EEStateChanged(let publication, let state):
            return "trackE2EEStateChanged \(trackDescription(publication)) state=\(state)"
        case .mediaKeyApplied(let keyIndex, let participantId):
            return "mediaKeyApplied participant=\(participantId) keyIndex=\(keyIndex)"
        }
    }

    static func participantDescription(_ participant: MatrixRTCLiveKitParticipantInfo) -> String {
        let identity = participant.identity ?? "nil"
        let sid = participant.sid ?? "nil"
        return "identity=\(identity) sid=\(sid)"
    }

    static func trackDescription(_ publication: MatrixRTCLiveKitTrackPublicationInfo) -> String {
        "sid=\(publication.sid) name=\(publication.name) kind=\(publication.kind) source=\(publication.source) muted=\(publication.isMuted) subscribed=\(publication.isSubscribed)"
    }
}

private struct NativeMatrixRTCCall {
    let attemptID: UUID
    let roomId: String
    let ownUserId: String
    let matrixRTCSession: MatrixRTCSession
    let liveKitSession: MatrixRTCLiveKitRoomSession
    let discoveredTransport: MatrixRTCLiveKitDiscoveredTransport
    let sfuConfig: MatrixRTCLiveKitSFUConfig
    let autoLeaveWhenOthersLeft: Bool
    let pickupAttempt: NativeMatrixRTCCallPickupAttempt?
}

private struct NativeMatrixRTCCallTasksToCancel {
    static let empty = NativeMatrixRTCCallTasksToCancel()

    var membershipRefreshTask: Task<Void, Never>? = nil
    var mediaKeyReshareTask: Task<Void, Never>? = nil
    var pickupTimeoutTask: Task<Void, Never>? = nil
    var pickupDeclineHandle: TaskHandle? = nil
    var autoLeaveWhenOthersLeftTask: Task<Void, Never>? = nil

    func cancel() {
        membershipRefreshTask?.cancel()
        mediaKeyReshareTask?.cancel()
        pickupTimeoutTask?.cancel()
        pickupDeclineHandle?.cancel()
        autoLeaveWhenOthersLeftTask?.cancel()
    }
}

private enum NativeMatrixRTCCallSubjectEmission: @unchecked Sendable {
    case state(NativeMatrixRTCCallServiceState)
    case participants(NativeMatrixRTCCallParticipantsSnapshot)
    case pickupState(NativeMatrixRTCCallPickupState)
}

private final class NativeMatrixRTCCallSubjectEmitter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ru.zyna.matrixrtc.native-call-service.subject-emitter")
    private let stateSubject: CurrentValueSubject<NativeMatrixRTCCallServiceState, Never>
    private let participantsSubject: CurrentValueSubject<NativeMatrixRTCCallParticipantsSnapshot, Never>
    private let pickupStateSubject: CurrentValueSubject<NativeMatrixRTCCallPickupState, Never>

    init(
        stateSubject: CurrentValueSubject<NativeMatrixRTCCallServiceState, Never>,
        participantsSubject: CurrentValueSubject<NativeMatrixRTCCallParticipantsSnapshot, Never>,
        pickupStateSubject: CurrentValueSubject<NativeMatrixRTCCallPickupState, Never>
    ) {
        self.stateSubject = stateSubject
        self.participantsSubject = participantsSubject
        self.pickupStateSubject = pickupStateSubject
    }

    func enqueue(_ emission: NativeMatrixRTCCallSubjectEmission) {
        enqueue([emission])
    }

    func enqueue(_ emissions: [NativeMatrixRTCCallSubjectEmission]) {
        guard !emissions.isEmpty else { return }
        queue.async { [self] in
            for emission in emissions {
                send(emission)
            }
        }
    }

    private func send(_ emission: NativeMatrixRTCCallSubjectEmission) {
        switch emission {
        case .state(let state):
            stateSubject.send(state)
        case .participants(let snapshot):
            participantsSubject.send(snapshot)
        case .pickupState(let state):
            pickupStateSubject.send(state)
        }
    }
}

private struct NativeMatrixRTCCallPickupAttempt {
    let notificationEventId: String
    let expiresAt: Date
    let lifetimeMilliseconds: Int64
}

private final class NativeMatrixRTCCallDeclineListener: @unchecked Sendable, CallDeclineListener {
    private let callback: @Sendable (String) -> Void

    init(callback: @escaping @Sendable (String) -> Void) {
        self.callback = callback
    }

    func call(declinerUserId: String) {
        callback(declinerUserId)
    }
}

private extension NativeMatrixRTCCallPickupState {
    var isRinging: Bool {
        switch self {
        case .ringing:
            return true
        case .inactive, .answered, .declined, .timedOut:
            return false
        }
    }
}

private extension NativeMatrixRTCCallServiceState {
    var roomId: String? {
        switch self {
        case .idle:
            return nil
        case .joining(let roomId), .connected(let roomId), .leaving(let roomId):
            return roomId
        }
    }
}
