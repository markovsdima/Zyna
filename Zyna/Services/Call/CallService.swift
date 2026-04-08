//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import MatrixRustSDK
import AVFoundation
import GRDB

private let logCall = ScopedLog(.call)

// MARK: - Call Service Delegate (WebRTC integration point)

protocol CallServiceDelegate: AnyObject {
    /// Called when a remote SDP offer is received (incoming call).
    func callService(_ service: CallService, didReceiveOffer sdp: String, callId: String)

    /// Called when a remote SDP answer is received (outgoing call accepted).
    func callService(_ service: CallService, didReceiveAnswer sdp: String, callId: String)

    /// Called when remote ICE candidates are received.
    func callService(_ service: CallService, didReceiveICECandidates candidates: [ICECandidate], callId: String)

    /// Called when the call ends.
    func callService(_ service: CallService, didEndCall callId: String, reason: CallHangupReason)
}

// MARK: - Call Service

final class CallService {

    static let shared = CallService()

    // MARK: - State

    let stateSubject = CurrentValueSubject<CallState, Never>(.idle)
    var state: CallState { stateSubject.value }

    // MARK: - Delegate

    weak var delegate: CallServiceDelegate?

    // MARK: - Private

    private var signalingService: CallSignalingService?
    private var cancellables = Set<AnyCancellable>()
    private var ringTimeoutTask: Task<Void, Never>?
    private var currentCallIsOutgoing = false

    private let webRTCClient = WebRTCClient()

    private init() {
        self.delegate = webRTCClient
        webRTCClient.callService = self
        webRTCClient.observeCallState()
    }

    // MARK: - Start Outgoing Call

    /// Initiates an outgoing call in a room.
    /// After calling this, provide the SDP offer via `sendOffer(sdp:)`.
    func startCall(room: Room, timelineService: TimelineService) {
        guard !state.isActive else {
            logCall("Cannot start call: already active")
            return
        }

        let callId = CallIdGenerator.generate()
        let ownUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""

        let signaling = CallSignalingService(room: room, ownUserId: ownUserId)
        self.signalingService = signaling

        subscribeToSignalingEvents(signaling)
        signaling.subscribe(to: timelineService)

        currentCallIsOutgoing = true
        configureAudioSession()
        stateSubject.send(.outgoingRinging(callId: callId, roomId: room.id()))
        logCall("Starting outgoing call \(callId) in room \(room.id())")

        storeCallEvent(type: .invited, callId: callId, roomId: room.id(), isOutgoing: true)
        startRingTimeout(callId: callId)
    }

    /// Send SDP offer to the remote peer (called by WebRTC layer after creating offer).
    func sendOffer(sdp: String) async {
        guard case .outgoingRinging(let callId, _) = state else {
            logCall("Cannot send offer: not in outgoingRinging state")
            return
        }

        let content = CallInviteContent(callId: callId, sdp: sdp)
        do {
            try await signalingService?.sendInvite(content)
        } catch {
            logCall("Failed to send offer: \(error)")
            endCall(reason: .normal)
        }
    }

    /// Send SDP answer to the remote peer (called by WebRTC layer after creating answer).
    func sendAnswer(sdp: String) async {
        guard let callId = state.callId else {
            logCall("Cannot send answer: no active call")
            return
        }

        let content = CallAnswerContent(callId: callId, sdp: sdp)
        do {
            try await signalingService?.sendAnswer(content)
            if case .incomingRinging(let cid, let rid, _) = state {
                stateSubject.send(.connecting(callId: cid, roomId: rid))
            }
        } catch {
            logCall("Failed to send answer: \(error)")
            endCall(reason: .normal)
        }
    }

    /// Send ICE candidates to the remote peer.
    func sendICECandidates(_ candidates: [ICECandidate]) async {
        guard let callId = state.callId else { return }

        let content = CallCandidatesContent(callId: callId, candidates: candidates)
        do {
            try await signalingService?.sendCandidates(content)
        } catch {
            logCall("Failed to send ICE candidates: \(error)")
        }
    }

    /// Mark call as connected (called by WebRTC layer when peer connection is established).
    func markConnected() {
        guard let callId = state.callId, let roomId = state.roomId else { return }

        cancelRingTimeout()
        stateSubject.send(.connected(callId: callId, roomId: roomId))
        logCall("Call \(callId) connected")
    }

    // MARK: - Accept Incoming Call

    func acceptCall() {
        guard case .incomingRinging(let callId, let roomId, _) = state else {
            logCall("Cannot accept: not in incomingRinging state")
            return
        }

        cancelRingTimeout()
        configureAudioSession()
        stateSubject.send(.connecting(callId: callId, roomId: roomId))
        logCall("Accepted call \(callId)")
    }

    // MARK: - End Call

    func endCall(reason: CallHangupReason = .userHangup) {
        guard let callId = state.callId else {
            stateSubject.send(.idle)
            return
        }

        cancelRingTimeout()

        Task {
            let content = CallHangupContent(callId: callId, reason: reason)
            try? await signalingService?.sendHangup(content)
            signalingService?.stop()
            signalingService = nil
        }

        delegate?.callService(self, didEndCall: callId, reason: reason)
        deactivateAudioSession()

        if let roomId = state.roomId {
            storeCallEvent(
                type: .ended, callId: callId, roomId: roomId,
                isOutgoing: currentCallIsOutgoing, reason: reason.rawValue
            )
        }

        stateSubject.send(.ended(callId: callId, reason: reason))
        logCall("Call \(callId) ended: \(reason.rawValue)")

        // Reset to idle after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if case .ended = self?.state {
                self?.stateSubject.send(.idle)
            }
        }
    }

    // MARK: - Handle Incoming Call (called by TimelineService or push)

    func handleIncomingCall(room: Room, callId: String, callerName: String?, offerSDP: String?, timelineService: TimelineService) {
        guard !state.isActive else {
            logCall("Ignoring incoming call: already active")
            // TODO: Send busy hangup
            return
        }

        let ownUserId = (try? MatrixClientService.shared.client?.userId()) ?? ""

        let signaling = CallSignalingService(room: room, ownUserId: ownUserId)
        self.signalingService = signaling

        subscribeToSignalingEvents(signaling)
        signaling.subscribe(to: timelineService)

        currentCallIsOutgoing = false
        stateSubject.send(.incomingRinging(callId: callId, roomId: room.id(), callerName: callerName))
        logCall("Incoming call \(callId) from \(callerName ?? "unknown") in room \(room.id())")

        storeCallEvent(type: .invited, callId: callId, roomId: room.id(), isOutgoing: false)

        // Deliver offer SDP directly — the invite event was already published
        // before signaling subscribed (PassthroughSubject race condition)
        if let sdp = offerSDP {
            logCall("Delivering offer SDP directly (\(sdp.count) bytes)")
            delegate?.callService(self, didReceiveOffer: sdp, callId: callId)
        }

        startRingTimeout(callId: callId)
    }

    // MARK: - Private — Signaling Events

    private func subscribeToSignalingEvents(_ signaling: CallSignalingService) {
        cancellables.removeAll()

        signaling.incomingEventSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleSignalingEvent(event)
            }
            .store(in: &cancellables)
    }

    private func handleSignalingEvent(_ event: CallSignalingEvent) {
        guard let callId = state.callId else { return }

        switch event {
        case .invite(let content):
            guard content.callId == callId else { return }
            delegate?.callService(self, didReceiveOffer: content.offer.sdp, callId: content.callId)

        case .answer(let content):
            guard content.callId == callId else { return }
            cancelRingTimeout()
            if case .outgoingRinging(_, let roomId) = state {
                stateSubject.send(.connecting(callId: callId, roomId: roomId))
            }
            delegate?.callService(self, didReceiveAnswer: content.answer.sdp, callId: content.callId)

        case .candidates(let content):
            guard content.callId == callId else { return }
            delegate?.callService(self, didReceiveICECandidates: content.candidates, callId: content.callId)

        case .hangup(let content):
            guard content.callId == callId else { return }
            let reason = CallHangupReason(rawValue: content.reason ?? "remote_hangup") ?? .remoteHangup
            endCall(reason: reason)
        }
    }

    // MARK: - Ring Timeout

    private func startRingTimeout(callId: String) {
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
            guard !Task.isCancelled else { return }
            guard self?.state.callId == callId else { return }

            await MainActor.run {
                logCall("Call \(callId) timed out")
                self?.endCall(reason: .timeout)
            }
        }
    }

    private func cancelRingTimeout() {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
    }

    // MARK: - GRDB Call Events

    private func storeCallEvent(
        type: CallEventType,
        callId: String,
        roomId: String,
        isOutgoing: Bool,
        reason: String? = nil
    ) {
        let senderId = (try? MatrixClientService.shared.client?.userId()) ?? ""
        let record = StoredMessage(
            id: "call-\(callId)-\(type.rawValue)",
            roomId: roomId,
            eventId: nil,
            transactionId: nil,
            senderId: senderId,
            senderDisplayName: nil,
            isOutgoing: isOutgoing,
            timestamp: Date().timeIntervalSince1970,
            contentType: "call",
            contentBody: callId,
            contentMediaJSON: nil,
            contentImageWidth: nil,
            contentImageHeight: nil,
            contentCaption: type.rawValue,
            contentVoiceDuration: nil,
            contentVoiceWaveform: nil,
            contentFilename: nil,
            contentMimetype: reason,
            contentFileSize: nil,
            reactionsJSON: "[]",
            sendStatus: "synced",
            replyEventId: nil,
            replySenderId: nil,
            replySenderName: nil,
            replyBody: nil,
            zynaAttributesJSON: nil
        )

        let dbQueue = DatabaseService.shared.dbQueue
        do {
            try dbQueue.write { db in
                try record.save(db)
            }
            logCall("Stored call event: \(type.rawValue) for \(callId)")
        } catch {
            logCall("Failed to store call event: \(error)")
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
            logCall("Audio session configured")
        } catch {
            logCall("Failed to configure audio session: \(error)")
        }
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            logCall("Audio session deactivated")
        } catch {
            logCall("Failed to deactivate audio session: \(error)")
        }
    }
}
