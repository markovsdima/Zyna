//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Combine
import WebRTC

private let logCall = ScopedLog(.call)

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
                logCall("User accepted — processing buffered offer")
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
            logCall("Ignoring duplicate createOffer — peer connection already exists")
            return
        }

        await createPeerConnection()
        addLocalAudioTrack()

        do {
            guard let pc = peerConnection else { return }

            let offer = try await pc.offer(for: WebRTCAudioConfig.offerConstraints)
            try await pc.setLocalDescription(offer)

            logCall("Created SDP offer (\(offer.sdp.count) bytes)")
            await callService?.sendOffer(sdp: offer.sdp)
            flushLocalCandidates()
        } catch {
            logCall("Failed to create offer: \(error)")
            callService?.endCall(reason: .normal)
        }
    }

    // MARK: - Incoming Call — Handle Offer & Create Answer

    private func handleRemoteOffer(sdp: String) async {
        // Guard against duplicate offers — only create if no active peer connection
        guard peerConnection == nil else {
            logCall("Ignoring duplicate offer — peer connection already exists")
            return
        }

        // Save remote candidates that arrived before peer connection was created.
        // createPeerConnection() calls resetICEQueue() which would lose them.
        let earlyRemoteCandidates = pendingICECandidates
        if !earlyRemoteCandidates.isEmpty {
            logCall("Preserving \(earlyRemoteCandidates.count) early remote ICE candidates")
        }

        await createPeerConnection()
        pendingICECandidates = earlyRemoteCandidates
        addLocalAudioTrack()

        do {
            guard let pc = peerConnection else { return }

            let remoteDesc = RTCSessionDescription(type: .offer, sdp: sdp)
            try await pc.setRemoteDescription(remoteDesc)
            setHasRemoteDescription(true)
            processPendingICECandidates()

            let answer = try await pc.answer(for: WebRTCAudioConfig.offerConstraints)
            try await pc.setLocalDescription(answer)

            logCall("Created SDP answer (\(answer.sdp.count) bytes)")
            await callService?.sendAnswer(sdp: answer.sdp)
            flushLocalCandidates()
        } catch {
            logCall("Failed to handle offer / create answer: \(error)")
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
            logCall("Set remote answer")
        } catch {
            logCall("Failed to set remote answer: \(error)")
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
                    logCall("Failed to add ICE candidate: \(error)")
                }
            } else {
                pendingICECandidates.append(rtcCandidate)
            }
        }
    }

    // MARK: - Peer Connection

    private func createPeerConnection() async {
        if peerConnection != nil {
            peerConnection?.close()
            peerConnection = nil
        }

        resetICEQueue()

        let iceServers = await TURNService.shared.iceServers()
        for server in iceServers {
            let hasCredential = server.credential != nil
            logCall("ICE server: \(server.urlStrings) credential=\(hasCredential)")
        }
        let config = WebRTCAudioConfig.peerConnectionConfig(iceServers: iceServers)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        logCall("Peer connection created with \(iceServers.count) ICE servers")
    }

    // MARK: - Audio Track

    private func addLocalAudioTrack() {
        let audioSource = factory.audioSource(with: WebRTCAudioConfig.audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio_\(UUID().uuidString)")
        audioTrack.isEnabled = true
        localAudioTrack = audioTrack

        peerConnection?.add(audioTrack, streamIds: ["local_stream"])
        logCall("Local audio track added")

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
            logCall("Audio gain configured (64-128 kbps)")
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

        logCall("Processing \(candidates.count) pending ICE candidates")

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

        logCall("Flushing \(candidates.count) queued local ICE candidates")
        Task {
            await callService?.sendICECandidates(candidates)
        }
    }

    // MARK: - Mute

    func setMuted(_ muted: Bool) {
        localAudioTrack?.isEnabled = !muted
        logCall("Microphone \(muted ? "muted" : "unmuted")")
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
        logCall("Received remote offer for call \(callId) (state: \(service.state))")

        // For incoming calls: buffer the offer until user accepts (state → .connecting)
        if case .incomingRinging = service.state {
            logCall("Buffering offer — waiting for user to accept")
            pendingOfferSDP = sdp
            return
        }

        Task { await handleRemoteOffer(sdp: sdp) }
    }

    func callService(_ service: CallService, didReceiveAnswer sdp: String, callId: String) {
        logCall("Received remote answer for call \(callId)")
        Task { await handleRemoteAnswer(sdp: sdp) }
    }

    func callService(_ service: CallService, didReceiveICECandidates candidates: [ICECandidate], callId: String) {
        logCall("Received \(candidates.count) remote ICE candidates")
        Task { await handleRemoteICECandidates(candidates) }
    }

    func callService(_ service: CallService, didEndCall callId: String, reason: CallHangupReason) {
        logCall("Call ended: \(reason.rawValue)")
        cleanup()
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        logCall("Signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        for audioTrack in stream.audioTracks {
            audioTrack.isEnabled = true
        }
        logCall("Remote stream added (audio tracks: \(stream.audioTracks.count))")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        logCall("Remote stream removed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        logCall("ICE connection state: \(newState.rawValue)")

        switch newState {
        case .connected, .completed:
            DispatchQueue.main.async { [weak self] in
                self?.callService?.markConnected()
            }

        case .failed:
            logCall("ICE failed — attempting restart")
            peerConnection.restartIce()

        case .disconnected:
            // Wait briefly then restart if still in call
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard self?.callService?.state.isActive == true else { return }
                logCall("ICE still disconnected — restarting")
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
        let candidateType: String
        let sdp = candidate.sdp
        if sdp.contains("relay") { candidateType = "relay (TURN)" }
        else if sdp.contains("srflx") { candidateType = "srflx (STUN)" }
        else if sdp.contains("prflx") { candidateType = "prflx (peer)" }
        else { candidateType = "host (local)" }
        logCall("ICE candidate generated: \(candidateType) — \(sdp)")

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
        logCall("ICE candidates removed: \(candidates.count)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        let label = switch newState {
        case .new: "new"
        case .gathering: "gathering"
        case .complete: "complete"
        @unknown default: "unknown(\(newState.rawValue))"
        }
        logCall("ICE gathering state: \(label)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver) {
        if let track = rtpReceiver.track {
            track.isEnabled = true
            logCall("RTP receiver added: \(track.kind)")
        }
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        logCall("Renegotiation needed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        logCall("Data channel opened: \(dataChannel.label)")
    }
}
