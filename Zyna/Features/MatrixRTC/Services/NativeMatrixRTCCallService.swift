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

    let stateSubject = CurrentValueSubject<NativeMatrixRTCCallServiceState, Never>(.idle)
    let participantsSubject = CurrentValueSubject<NativeMatrixRTCCallParticipantsSnapshot, Never>(.empty)

    var state: NativeMatrixRTCCallServiceState {
        stateSubject.value
    }

    private let lock = NSLock()
    // Local generation id used to ignore stale events from canceled join attempts.
    private var currentCallAttemptID: UUID?
    private var activeCall: NativeMatrixRTCCall?
    private var membershipRefreshTask: Task<Void, Never>?
    private var participantStore = NativeMatrixRTCCallParticipantStore()
    private let audioSessionController = NativeMatrixRTCAudioSessionController.shared

    private init() {}

    @discardableResult
    func startAudioCall(
        room: Room,
        fallbackLiveKitServiceURL: String? = nil
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
                    log("MatrixRTC media key transport error: \(error)")
                }
            )
            matrixRTCSession = session

            let joinResult = try await session.join()
            try Task.checkCancellation()
            await sendCallNotificationIfNeeded(room: room, joinResult: joinResult)
            try Task.checkCancellation()
            try audioSessionController.configureForCall()
            try Task.checkCancellation()
            try await liveKit.connect(sfuConfig: sfuConfig, publishAudio: true)
            try Task.checkCancellation()

            let call = NativeMatrixRTCCall(
                attemptID: attemptID,
                roomId: roomId,
                matrixRTCSession: session,
                liveKitSession: liveKit,
                discoveredTransport: discoveredTransport,
                sfuConfig: sfuConfig
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
            switch stateSubject.value {
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
        try withLock {
            if let activeCall {
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: activeCall.roomId)
            }

            if currentCallAttemptID != nil {
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: stateSubject.value.roomId ?? roomId)
            }

            switch stateSubject.value {
            case .idle:
                let attemptID = UUID()
                currentCallAttemptID = attemptID
                stateSubject.send(.joining(roomId: roomId))
                return attemptID
            case .joining(let roomId), .connected(let roomId), .leaving(let roomId):
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: roomId)
            }
        }
    }

    func finishJoined(_ call: NativeMatrixRTCCall) -> Bool {
        withLock {
            guard currentCallAttemptID == call.attemptID else { return false }
            guard case .joining = stateSubject.value else { return false }
            activeCall = call
            stateSubject.send(.connected(roomId: call.roomId))
            return true
        }
    }

    func finishFailed(attemptID: UUID) {
        let snapshot: NativeMatrixRTCCallParticipantsSnapshot? = withLock {
            guard currentCallAttemptID == attemptID else { return nil }
            membershipRefreshTask?.cancel()
            membershipRefreshTask = nil
            currentCallAttemptID = nil
            activeCall = nil
            stateSubject.send(.idle)
            return participantStore.reset(roomId: nil)
        }
        guard let snapshot else { return }
        participantsSubject.send(snapshot)
    }

    func beginLeaving(reason: String) -> NativeMatrixRTCCall? {
        beginLeaving(reason: reason, attemptID: nil)
    }

    func beginLeaving(reason: String, attemptID: UUID?) -> NativeMatrixRTCCall? {
        withLock {
            if let attemptID, currentCallAttemptID != attemptID {
                return nil
            }

            guard let activeCall else {
                guard currentCallAttemptID != nil else {
                    stateSubject.send(.idle)
                    return nil
                }

                switch stateSubject.value {
                case .joining(let roomId):
                    membershipRefreshTask?.cancel()
                    membershipRefreshTask = nil
                    stateSubject.send(.leaving(roomId: roomId))
                    log("Ending native MatrixRTC call in room \(roomId) reason=\(reason)")
                case .idle:
                    stateSubject.send(.idle)
                case .connected(let roomId), .leaving(let roomId):
                    stateSubject.send(.leaving(roomId: roomId))
                }
                return nil
            }

            switch stateSubject.value {
            case .leaving:
                return nil
            case .idle, .joining, .connected:
                membershipRefreshTask?.cancel()
                membershipRefreshTask = nil
                stateSubject.send(.leaving(roomId: activeCall.roomId))
                log("Ending native MatrixRTC call in room \(activeCall.roomId) reason=\(reason)")
                return activeCall
            }
        }
    }

    func finishLeft(attemptID: UUID) {
        let snapshot: NativeMatrixRTCCallParticipantsSnapshot? = withLock {
            guard currentCallAttemptID == attemptID else { return nil }
            membershipRefreshTask?.cancel()
            membershipRefreshTask = nil
            currentCallAttemptID = nil
            activeCall = nil
            stateSubject.send(.idle)
            return participantStore.reset(roomId: nil)
        }
        guard let snapshot else { return }
        participantsSubject.send(snapshot)
    }

    func currentActiveCall() -> NativeMatrixRTCCall? {
        withLock { activeCall }
    }

    func resetParticipantState(roomId: String?) {
        let snapshot = withLock {
            participantStore.reset(roomId: roomId)
        }
        participantsSubject.send(snapshot)
    }

    func setLocalParticipantIdentity(_ identity: String?) {
        let snapshot = withLock {
            participantStore.setLocalIdentity(identity)
        }
        participantsSubject.send(snapshot)
    }

    func handleLiveKitEvent(_ event: MatrixRTCLiveKitRoomSessionEvent, attemptID: UUID) {
        let snapshot: NativeMatrixRTCCallParticipantsSnapshot? = withLock {
            guard currentCallAttemptID == attemptID else { return nil }
            guard participantStore.snapshot.roomId != nil else { return nil }
            return participantStore.apply(event)
        }
        guard let snapshot else { return }
        participantsSubject.send(snapshot)
    }

    func sendCallNotificationIfNeeded(
        room: Room,
        joinResult: MatrixRTCSessionJoinResult
    ) async {
        guard Self.shouldSendCallNotification(
            ownMembership: joinResult.ownMembership,
            memberships: joinResult.memberships
        ) else {
            return
        }

        do {
            let result = try await MatrixRustSDKRTCCallNotificationClient(room: room).sendCallNotification(
                parentEventId: joinResult.ownMembership.eventId,
                slot: joinResult.ownMembership.slot,
                notificationType: .ring,
                callIntent: Self.audioCallIntent
            )
            log("Sent MatrixRTC call notification for room \(room.id()) parent=\(joinResult.ownMembership.eventId) notification=\(result.sentNotification) notificationEventId=\(result.notificationEventId ?? "nil") legacy=\(result.sentLegacyFallback) legacyEventId=\(result.legacyFallbackEventId ?? "nil") legacyCallId=\(joinResult.ownMembership.slot.id)")
        } catch {
            log("Failed sending MatrixRTC call notification for room \(room.id()): \(error)")
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

        withLock {
            membershipRefreshTask?.cancel()
            membershipRefreshTask = refreshTask
        }
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

                if sharedCount > 0 {
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
    let matrixRTCSession: MatrixRTCSession
    let liveKitSession: MatrixRTCLiveKitRoomSession
    let discoveredTransport: MatrixRTCLiveKitDiscoveredTransport
    let sfuConfig: MatrixRTCLiveKitSFUConfig
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
