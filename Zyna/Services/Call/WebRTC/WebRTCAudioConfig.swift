//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import WebRTC

// MARK: - WebRTC Audio Configuration

enum WebRTCAudioConfig {

    /// Audio constraints: echo cancellation, noise suppression, AGC with gain boost.
    static let audioConstraints = RTCMediaConstraints(
        mandatoryConstraints: [
            "googEchoCancellation": "true",
            "googNoiseSuppression": "true",
            "googAutoGainControl": "true",
            "googHighpassFilter": "false",
            "googTypingNoiseDetection": "false",
            "googAudioMirroring": "false",
            "googAGCStartupMinVolume": "12",
            "googAGCTargetLevelDbov": "3",
            "googAGCCompressionGainDb": "20"
        ],
        optionalConstraints: [
            "googDAEchoCancellation": "true",
            "googNoiseReduction": "false"
        ]
    )

    /// Offer/answer constraints for audio-only calls.
    static let offerConstraints = RTCMediaConstraints(
        mandatoryConstraints: ["OfferToReceiveAudio": "true"],
        optionalConstraints: nil
    )

    /// RTCConfiguration for peer connections with TURN credentials from the homeserver.
    static func peerConnectionConfig(iceServers: [RTCIceServer]) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.sdpSemantics = .unifiedPlan
        config.iceTransportPolicy = .all
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 10
        return config
    }
}
