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

    let stateSubject = CurrentValueSubject<NativeMatrixRTCCallServiceState, Never>(.idle)

    var state: NativeMatrixRTCCallServiceState {
        stateSubject.value
    }

    private let lock = NSLock()
    private var activeCall: NativeMatrixRTCCall?

    private init() {}

    @discardableResult
    func startAudioCall(
        room: Room,
        fallbackLiveKitServiceURL: String? = nil
    ) async throws -> NativeMatrixRTCCallStartResult {
        let roomId = room.id()
        try beginJoining(roomId: roomId)

        var matrixRTCSession: MatrixRTCSession?
        var liveKitSession: MatrixRTCLiveKitRoomSession?

        do {
            guard let client = MatrixClientService.shared.client else {
                throw NativeMatrixRTCCallServiceError.missingMatrixClient
            }

            let focusClient = MatrixRustSDKRTCLiveKitFocusClient(client: client)
            guard let discoveredTransport = try await focusClient.discoverPreferredTransport(
                fallbackServiceURL: fallbackLiveKitServiceURL
            ) else {
                throw NativeMatrixRTCCallServiceError.missingLiveKitTransport
            }

            let ownIdentity = try Self.legacyMembershipIdentity(client: client)
            let sfuConfig = try await focusClient.sfuConfig(
                for: ownIdentity,
                transport: discoveredTransport.transport,
                roomId: roomId,
                endpointVersion: .legacy
            )

            let liveKit = MatrixRTCLiveKitRoomSession(onEvent: { event in
                log("LiveKit \(Self.liveKitEventDescription(event))")
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
                    callIntent: "m.audio"
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
            try await liveKit.connect(sfuConfig: sfuConfig, publishAudio: true)

            finishJoined(.init(
                roomId: roomId,
                matrixRTCSession: session,
                liveKitSession: liveKit,
                discoveredTransport: discoveredTransport,
                sfuConfig: sfuConfig
            ))

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
            finishFailed()
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

    func leaveActiveCall() async throws {
        guard let call = beginLeaving() else {
            return
        }

        await call.liveKitSession.disconnect()
        defer {
            finishLeft()
        }

        _ = try await call.matrixRTCSession.leave()
        log("Left native MatrixRTC call in room \(call.roomId)")
    }
}

private extension NativeMatrixRTCCallService {
    func beginJoining(roomId: String) throws {
        try withLock {
            if let activeCall {
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: activeCall.roomId)
            }

            switch stateSubject.value {
            case .idle:
                stateSubject.send(.joining(roomId: roomId))
            case .joining(let roomId), .connected(let roomId), .leaving(let roomId):
                throw NativeMatrixRTCCallServiceError.alreadyActive(roomId: roomId)
            }
        }
    }

    func finishJoined(_ call: NativeMatrixRTCCall) {
        withLock {
            activeCall = call
            stateSubject.send(.connected(roomId: call.roomId))
        }
    }

    func finishFailed() {
        withLock {
            activeCall = nil
            stateSubject.send(.idle)
        }
    }

    func beginLeaving() -> NativeMatrixRTCCall? {
        withLock {
            guard let activeCall else {
                stateSubject.send(.idle)
                return nil
            }

            stateSubject.send(.leaving(roomId: activeCall.roomId))
            return activeCall
        }
    }

    func finishLeft() {
        withLock {
            activeCall = nil
            stateSubject.send(.idle)
        }
    }

    func currentActiveCall() -> NativeMatrixRTCCall? {
        withLock { activeCall }
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
    let roomId: String
    let matrixRTCSession: MatrixRTCSession
    let liveKitSession: MatrixRTCLiveKitRoomSession
    let discoveredTransport: MatrixRTCLiveKitDiscoveredTransport
    let sfuConfig: MatrixRTCLiveKitSFUConfig
}
