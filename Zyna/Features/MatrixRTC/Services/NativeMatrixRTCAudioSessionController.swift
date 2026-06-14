//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Foundation
import MatrixRTCLiveKit

private let log = ScopedLog(.call, prefix: "[matrixrtc-native]")

final class NativeMatrixRTCAudioSessionController: @unchecked Sendable {
    static let shared = NativeMatrixRTCAudioSessionController()

    private let lock = NSLock()
    private var isConfigured = false
    private var previousSpeakerOutputPreference: Bool?

    var isSpeakerEnabled: Bool {
        MatrixRTCLiveKitAudioRouting.isBuiltInSpeakerActive
    }

    private init() {}

    func configureForCall() throws {
        let previousPreference = MatrixRTCLiveKitAudioRouting.isSpeakerOutputPreferred
        withLock {
            if !isConfigured {
                previousSpeakerOutputPreference = previousPreference
            }
            isConfigured = true
        }

        MatrixRTCLiveKitAudioRouting.setSpeakerOutputPreferred(false)

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            deactivateAfterCall()
            throw error
        }

        log("Audio session configured for MatrixRTC call route=\(routeDescription())")
    }

    func deactivateAfterCall() {
        let (wasConfigured, previousPreference) = withLock {
            let wasConfigured = isConfigured
            isConfigured = false
            let preference = previousSpeakerOutputPreference
            previousSpeakerOutputPreference = nil
            return (wasConfigured, preference)
        }
        guard wasConfigured else { return }
        defer {
            if let previousPreference {
                MatrixRTCLiveKitAudioRouting.setSpeakerOutputPreferred(previousPreference)
            }
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.overrideOutputAudioPort(.none)
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            log("Audio session deactivated after MatrixRTC call")
        } catch {
            log("Failed deactivating MatrixRTC audio session: \(error)")
        }
    }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        MatrixRTCLiveKitAudioRouting.setSpeakerOutputPreferred(enabled)
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        log("MatrixRTC speaker output \(enabled ? "enabled" : "disabled") route=\(routeDescription())")
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func routeDescription() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return "none" }
        return outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
    }
}
