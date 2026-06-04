//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import CallKit
import Combine
import Foundation
import MatrixRustSDK
import PushKit
import UIKit

private let logElementCallKit = ScopedLog(.call, prefix: "[ElementCallKit]")

enum ElementCallKitAction {
    case receivedIncomingCallRequest
    case startCall(roomID: String, isVoiceCall: Bool)
    case endCall(roomID: String)
    case setAudioEnabled(Bool, roomID: String)
}

enum ElementCallKitPayloadKey: String {
    case roomID
    case roomDisplayName
    case rtcNotifyEventID
    case expirationDate
    case isVoiceCall
}

final class ElementCallKitService: NSObject {

    static let shared = ElementCallKitService()

    var actions: AnyPublisher<ElementCallKitAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }

    let ongoingCallRoomIDSubject = CurrentValueSubject<String?, Never>(nil)

    private struct CallID {
        let callKitID: UUID
        let roomID: String
        let rtcNotificationID: String?
        let isVoiceCall: Bool
    }

    private let actionsSubject = PassthroughSubject<ElementCallKitAction, Never>()
    private let pushRegistry: PKPushRegistry
    private let callProvider: CXProvider
    private let callController = CXCallController()

    private var incomingCallID: CallID?
    private var ongoingCallID: CallID? {
        didSet {
            ongoingCallRoomIDSubject.send(ongoingCallID?.roomID)
        }
    }
    private var endUnansweredCallWorkItem: DispatchWorkItem?

    private override init() {
        pushRegistry = PKPushRegistry(queue: .main)

        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.includesCallsInRecents = true
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]

        if let icon = UIImage(named: "AppIcon") {
            configuration.iconTemplateImageData = icon.pngData()
        }

        callProvider = CXProvider(configuration: configuration)

        super.init()

        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        callProvider.setDelegate(self, queue: .main)
    }

    func start() {
        // Touching the singleton is enough to register PushKit and CallKit delegates.
    }

    func setupCallSession(roomID: String, roomDisplayName: String) {
        if ongoingCallID != nil {
            tearDownCallSession()
        }

        let callID: CallID
        if let incomingCallID, incomingCallID.roomID == roomID {
            callID = incomingCallID
        } else {
            callID = CallID(
                callKitID: UUID(),
                roomID: roomID,
                rtcNotificationID: nil,
                isVoiceCall: false
            )
        }

        incomingCallID = nil
        ongoingCallID = callID
        logElementCallKit("Element Call session started for room \(roomID) (\(roomDisplayName))")

        // Do not start a new CallKit session here. Element Call runs in WKWebView,
        // and an active CallKit media session can prevent WebKit from getting
        // camera and microphone streams.
    }

    func tearDownCallSession() {
        ongoingCallID = nil
        cancelUnansweredCallTimeout()
        logElementCallKit("Element Call session cleared")
    }

    func setAudioEnabled(_ enabled: Bool, roomID: String) {
        guard let ongoingCallID else {
            logElementCallKit("Failed toggling audio: no ongoing Element Call")
            return
        }
        guard ongoingCallID.roomID == roomID else {
            logElementCallKit("Failed toggling audio: room mismatch \(ongoingCallID.roomID) != \(roomID)")
            return
        }

        let action = CXSetMutedCallAction(call: ongoingCallID.callKitID, muted: !enabled)
        callController.request(CXTransaction(action: action)) { error in
            if let error {
                logElementCallKit("Failed requesting CallKit mute transaction: \(error)")
            }
        }
    }

    private func cancelUnansweredCallTimeout() {
        endUnansweredCallWorkItem?.cancel()
        endUnansweredCallWorkItem = nil
    }

    private func reportUnansweredCall(_ callID: CallID, after ringDuration: TimeInterval) {
        cancelUnansweredCallTimeout()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard incomingCallID?.callKitID == callID.callKitID else { return }
            logElementCallKit("Incoming call timed out for room \(callID.roomID)")
            callProvider.reportCall(with: callID.callKitID, endedAt: nil, reason: .unanswered)
            incomingCallID = nil
        }

        endUnansweredCallWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ringDuration, execute: workItem)
    }

    private func sendDeclineCallEvent(_ callID: CallID) async {
        guard let rtcNotificationID = callID.rtcNotificationID else {
            logElementCallKit("No RTC notification event to decline")
            return
        }

        guard let client = MatrixClientService.shared.client,
              let room = try? client.getRoom(roomId: callID.roomID) else {
            logElementCallKit("Failed to fetch room \(callID.roomID) for call decline")
            return
        }

        do {
            try await room.declineCall(rtcNotificationEventId: rtcNotificationID)
            logElementCallKit("Declined incoming call \(rtcNotificationID)")
        } catch {
            logElementCallKit("Failed declining incoming call \(rtcNotificationID): \(error)")
        }
    }
}

extension ElementCallKitService: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        logElementCallKit("PushKit credentials updated for \(type.rawValue)")
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        guard let roomID = payload.dictionaryPayload[ElementCallKitPayloadKey.roomID.rawValue] as? String else {
            logElementCallKit("Missing roomID in incoming VoIP payload")
            completion()
            return
        }

        guard let rtcNotificationID = payload.dictionaryPayload[ElementCallKitPayloadKey.rtcNotifyEventID.rawValue] as? String else {
            logElementCallKit("Missing rtcNotifyEventID in incoming VoIP payload")
            completion()
            return
        }

        guard ongoingCallID?.roomID != roomID else {
            logElementCallKit("Call is already ongoing for room \(roomID)")
            completion()
            return
        }

        guard let expirationDate = expirationDate(from: payload.dictionaryPayload) else {
            logElementCallKit("Missing expirationDate in incoming VoIP payload")
            completion()
            return
        }

        let now = Date()
        guard now < expirationDate else {
            logElementCallKit("Incoming call expired for room \(roomID)")
            completion()
            return
        }

        let isVoiceCall = payload.dictionaryPayload[ElementCallKitPayloadKey.isVoiceCall.rawValue] as? Bool ?? false
        let callID = CallID(
            callKitID: UUID(),
            roomID: roomID,
            rtcNotificationID: rtcNotificationID,
            isVoiceCall: isVoiceCall
        )
        incomingCallID = callID

        let update = CXCallUpdate()
        update.hasVideo = true
        update.localizedCallerName = payload.dictionaryPayload[ElementCallKitPayloadKey.roomDisplayName.rawValue] as? String
        update.remoteHandle = CXHandle(type: .generic, value: roomID)
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        callProvider.reportNewIncomingCall(with: callID.callKitID, update: update) { [weak self] error in
            if let error {
                logElementCallKit("Failed reporting incoming Element Call: \(error)")
            }

            self?.actionsSubject.send(.receivedIncomingCallRequest)
            completion()
        }

        reportUnansweredCall(
            callID,
            after: min(expirationDate.timeIntervalSince(now), 90)
        )
    }

    private func expirationDate(from payload: [AnyHashable: Any]) -> Date? {
        if let date = payload[ElementCallKitPayloadKey.expirationDate.rawValue] as? Date {
            return date
        }
        if let timestamp = payload[ElementCallKitPayloadKey.expirationDate.rawValue] as? TimeInterval {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }
}

extension ElementCallKitService: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        logElementCallKit("CallKit provider reset")
        incomingCallID = nil
        ongoingCallID = nil
        cancelUnansweredCallTimeout()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        logElementCallKit("CallKit audio session activated")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        logElementCallKit("CallKit audio session deactivated")
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let incomingCallID else {
            logElementCallKit("Failed answering incoming call: missing incomingCallID")
            action.fail()
            return
        }

        action.fulfill()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            provider.reportCall(with: incomingCallID.callKitID, endedAt: nil, reason: .remoteEnded)
            actionsSubject.send(.startCall(roomID: incomingCallID.roomID, isVoiceCall: incomingCallID.isVoiceCall))
            cancelUnansweredCallTimeout()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        #if targetEnvironment(simulator)
        logElementCallKit("Ignoring CallKit end action on simulator")
        action.fulfill()
        #else
        if let ongoingCallID {
            actionsSubject.send(.endCall(roomID: ongoingCallID.roomID))
        }

        if let incomingCallID {
            Task {
                await sendDeclineCallEvent(incomingCallID)
            }
        }

        incomingCallID = nil
        ongoingCallID = nil
        cancelUnansweredCallTimeout()
        action.fulfill()
        #endif
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let ongoingCallID {
            actionsSubject.send(.setAudioEnabled(!action.isMuted, roomID: ongoingCallID.roomID))
        } else {
            logElementCallKit("Failed handling CallKit mute action: missing ongoingCallID")
        }
        action.fulfill()
    }
}
