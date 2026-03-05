//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import CallKit
import AVFoundation

private let callLog = ScopedLog(.call)

// MARK: - CallKit Service

final class CallKitService: NSObject {

    // MARK: - Callbacks

    var onAnswerCall: (() -> Void)?
    var onEndCall: (() -> Void)?
    var onMuteToggle: ((Bool) -> Void)?

    // MARK: - Private

    private let provider: CXProvider
    private let callController = CXCallController()
    private var currentCallUUID: UUID?

    // MARK: - Init

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.iconTemplateImageData = nil // TODO: Set app icon

        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: - Report Incoming Call

    func reportIncomingCall(callId: String, handle: String) {
        let uuid = UUID()
        currentCallUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = handle
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                callLog("Failed to report incoming call: \(error)")
            } else {
                callLog("Reported incoming call to CallKit (uuid: \(uuid))")
            }
        }
    }

    // MARK: - Report Outgoing Call

    func reportOutgoingCall(callId: String, handle: String) {
        let uuid = UUID()
        currentCallUUID = uuid

        let handle = CXHandle(type: .generic, value: handle)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        startAction.isVideo = false

        callController.request(CXTransaction(action: startAction)) { error in
            if let error {
                callLog("Failed to start outgoing call: \(error)")
            } else {
                callLog("Started outgoing call in CallKit (uuid: \(uuid))")
            }
        }

        // Mark as connecting
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    // MARK: - Report Connected

    func reportCallConnected() {
        guard let uuid = currentCallUUID else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    // MARK: - Report Ended

    func reportCallEnded(reason: CallHangupReason) {
        guard let uuid = currentCallUUID else { return }

        let cxReason: CXCallEndedReason
        switch reason {
        case .normal, .userHangup:
            cxReason = .remoteEnded
        case .busy:
            cxReason = .unanswered
        case .timeout:
            cxReason = .unanswered
        case .declined:
            cxReason = .declinedElsewhere
        default:
            cxReason = .failed
        }

        provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
        currentCallUUID = nil
    }

    // MARK: - Configure Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try session.setActive(true)
            callLog("Audio session configured for voice call")
        } catch {
            callLog("Failed to configure audio session: \(error)")
        }
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            callLog("Failed to deactivate audio session: \(error)")
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitService: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        callLog("CallKit provider did reset")
        currentCallUUID = nil
        deactivateAudioSession()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        callLog("CallKit: answer call")
        configureAudioSession()
        onAnswerCall?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        callLog("CallKit: end call")
        onEndCall?()
        deactivateAudioSession()
        currentCallUUID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        callLog("CallKit: mute = \(action.isMuted)")
        onMuteToggle?(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        callLog("CallKit: audio session activated")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        callLog("CallKit: audio session deactivated")
    }
}
