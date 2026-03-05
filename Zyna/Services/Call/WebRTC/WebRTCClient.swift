//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import WebRTC

private let callLog = ScopedLog(.call)

// MARK: - WebRTC Client

/// Manages RTCPeerConnection for audio calls.
/// Implements CallServiceDelegate to receive signaling events from Matrix.
/// Observes CallService state to know when to create offers.
final class WebRTCClient: NSObject {

    /// Back-reference to CallService for sending SDP/ICE via Matrix.
    weak var callService: CallService?

    // MARK: - Private — WebRTC

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?

    // MARK: - Private — Pending Offer (incoming call, waiting for user to accept)

    private var pendingOfferSDP: String?

    // MARK: - Private — ICE Candidate Queue (incoming remote candidates)

    private var pendingICECandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false

    // MARK: - Private — Local Candidate Queue (outgoing, wait for invite/answer to be sent)

    private var pendingLocalCandidates: [ICECandidate] = []
    private var localDescriptionSent = false

    // MARK: - Private — State

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        super.init()
    }

    deinit {
        cleanup()
        RTCCleanupSSL()
    }

    // MARK: - State Observation

    /// Call this after setting callService to start observing state changes.
    func observeCallState() {
        callService?.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleStateChange(state)
            }
            .store(in: &cancellables)
    }

    private func handleStateChange(_ state: CallState) {
        switch state {
        case .outgoingRinging:
            Task { await createOfferAndSend() }

        case .connecting:
            // User accepted incoming call — process buffered offer
            if let sdp = pendingOfferSDP {
                pendingOfferSDP = nil
                callLog("User accepted — processing buffered offer")
                Task { await handleRemoteOffer(sdp: sdp) }
            }

        case .ended, .idle:
            cleanup()

        default:
            break
        }
    }

    // MARK: - Outgoing Call — Create Offer

    private func createOfferAndSend() async {
        guard peerConnection == nil else {
            callLog("Ignoring duplicate createOffer — peer connection already exists")
            return
        }

        createPeerConnection()
        addLocalAudioTrack()

        do {
            guard let pc = peerConnection else { return }

            let offer = try await pc.offer(for: WebRTCAudioConfig.offerConstraints)
            try await pc.setLocalDescription(offer)

            callLog("Created SDP offer (\(offer.sdp.count) bytes)")
            await callService?.sendOffer(sdp: offer.sdp)
            flushLocalCandidates()
        } catch {
            callLog("Failed to create offer: \(error)")
            callService?.endCall(reason: .normal)
        }
    }

    // MARK: - Incoming Call — Handle Offer & Create Answer

    private func handleRemoteOffer(sdp: String) async {
        // Guard against duplicate offers — only create if no active peer connection
        guard peerConnection == nil else {
            callLog("Ignoring duplicate offer — peer connection already exists")
            return
        }

        createPeerConnection()
        addLocalAudioTrack()

        do {
            guard let pc = peerConnection else { return }

            let remoteDesc = RTCSessionDescription(type: .offer, sdp: sdp)
            try await pc.setRemoteDescription(remoteDesc)
            setHasRemoteDescription(true)
            processPendingICECandidates()

            let answer = try await pc.answer(for: WebRTCAudioConfig.offerConstraints)
            try await pc.setLocalDescription(answer)

            callLog("Created SDP answer (\(answer.sdp.count) bytes)")
            await callService?.sendAnswer(sdp: answer.sdp)
            flushLocalCandidates()
        } catch {
            callLog("Failed to handle offer / create answer: \(error)")
            callService?.endCall(reason: .normal)
        }
    }

    // MARK: - Handle Remote Answer

    private func handleRemoteAnswer(sdp: String) async {
        do {
            let remoteDesc = RTCSessionDescription(type: .answer, sdp: sdp)
            try await peerConnection?.setRemoteDescription(remoteDesc)
            setHasRemoteDescription(true)
            processPendingICECandidates()
            callLog("Set remote answer")
        } catch {
            callLog("Failed to set remote answer: \(error)")
        }
    }

    // MARK: - Handle Remote ICE Candidates

    private func handleRemoteICECandidates(_ candidates: [ICECandidate]) async {
        for candidate in candidates {
            let rtcCandidate = RTCIceCandidate(
                sdp: candidate.candidate,
                sdpMLineIndex: Int32(candidate.sdpMLineIndex ?? 0),
                sdpMid: candidate.sdpMid
            )

            if hasRemoteDescription {
                do {
                    try await peerConnection?.add(rtcCandidate)
                } catch {
                    callLog("Failed to add ICE candidate: \(error)")
                }
            } else {
                pendingICECandidates.append(rtcCandidate)
            }
        }
    }

    // MARK: - Peer Connection

    private func createPeerConnection() {
        if peerConnection != nil {
            peerConnection?.close()
            peerConnection = nil
        }

        resetICEQueue()

        let config = WebRTCAudioConfig.peerConnectionConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        callLog("Peer connection created")
    }

    // MARK: - Audio Track

    private func addLocalAudioTrack() {
        let audioSource = factory.audioSource(with: WebRTCAudioConfig.audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio_\(UUID().uuidString)")
        audioTrack.isEnabled = true
        localAudioTrack = audioTrack

        peerConnection?.add(audioTrack, streamIds: ["local_stream"])
        callLog("Local audio track added")

        // Configure audio gain after a short delay for sender parameters to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.configureAudioGain()
        }
    }

    private func configureAudioGain() {
        guard let pc = peerConnection else { return }

        for transceiver in pc.transceivers where transceiver.mediaType == .audio {
            let parameters = transceiver.sender.parameters
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: 128_000)
                encoding.minBitrateBps = NSNumber(value: 64_000)
            }
            transceiver.sender.parameters = parameters
            callLog("Audio gain configured (64-128 kbps)")
            break
        }
    }

    // MARK: - ICE Queue

    private func setHasRemoteDescription(_ value: Bool) {
        hasRemoteDescription = value
    }

    private func processPendingICECandidates() {
        guard hasRemoteDescription, !pendingICECandidates.isEmpty else { return }

        let candidates = pendingICECandidates
        pendingICECandidates.removeAll()

        callLog("Processing \(candidates.count) pending ICE candidates")

        Task {
            for candidate in candidates {
                try? await peerConnection?.add(candidate)
            }
        }
    }

    private func resetICEQueue() {
        pendingICECandidates.removeAll()
        hasRemoteDescription = false
        pendingLocalCandidates.removeAll()
        localDescriptionSent = false
    }

    private func flushLocalCandidates() {
        localDescriptionSent = true
        guard !pendingLocalCandidates.isEmpty else { return }

        let candidates = pendingLocalCandidates
        pendingLocalCandidates.removeAll()

        callLog("Flushing \(candidates.count) queued local ICE candidates")
        Task {
            await callService?.sendICECandidates(candidates)
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
        peerConnection?.close()
        peerConnection = nil
        pendingOfferSDP = nil
        resetICEQueue()
    }
}

// MARK: - CallServiceDelegate

extension WebRTCClient: CallServiceDelegate {

    func callService(_ service: CallService, didReceiveOffer sdp: String, callId: String) {
        callLog("Received remote offer for call \(callId) (state: \(service.state))")

        // For incoming calls: buffer the offer until user accepts (state → .connecting)
        if case .incomingRinging = service.state {
            callLog("Buffering offer — waiting for user to accept")
            pendingOfferSDP = sdp
            return
        }

        Task { await handleRemoteOffer(sdp: sdp) }
    }

    func callService(_ service: CallService, didReceiveAnswer sdp: String, callId: String) {
        callLog("Received remote answer for call \(callId)")
        Task { await handleRemoteAnswer(sdp: sdp) }
    }

    func callService(_ service: CallService, didReceiveICECandidates candidates: [ICECandidate], callId: String) {
        callLog("Received \(candidates.count) remote ICE candidates")
        Task { await handleRemoteICECandidates(candidates) }
    }

    func callService(_ service: CallService, didEndCall callId: String, reason: CallHangupReason) {
        callLog("Call ended: \(reason.rawValue)")
        cleanup()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        callLog("Signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        for audioTrack in stream.audioTracks {
            audioTrack.isEnabled = true
        }
        callLog("Remote stream added (audio tracks: \(stream.audioTracks.count))")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        callLog("Remote stream removed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        callLog("ICE connection state: \(newState.rawValue)")

        switch newState {
        case .connected, .completed:
            DispatchQueue.main.async { [weak self] in
                self?.callService?.markConnected()
            }

        case .failed:
            callLog("ICE failed — attempting restart")
            peerConnection.restartIce()

        case .disconnected:
            // Wait briefly then restart if still in call
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard self?.callService?.state.isActive == true else { return }
                callLog("ICE still disconnected — restarting")
                peerConnection.restartIce()
            }

        case .closed:
            DispatchQueue.main.async { [weak self] in
                guard self?.callService?.state.isActive == true else { return }
                self?.callService?.endCall(reason: .iceFailed)
            }

        default:
            break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let iceCandidate = ICECandidate(
            candidate: candidate.sdp,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: Int(candidate.sdpMLineIndex)
        )

        if localDescriptionSent {
            Task {
                await callService?.sendICECandidates([iceCandidate])
            }
        } else {
            pendingLocalCandidates.append(iceCandidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        callLog("ICE candidates removed: \(candidates.count)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        callLog("ICE gathering state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver) {
        if let track = rtpReceiver.track {
            track.isEnabled = true
            callLog("RTP receiver added: \(track.kind)")
        }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        callLog("Renegotiation needed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        callLog("Data channel opened: \(dataChannel.label)")
    }
}
