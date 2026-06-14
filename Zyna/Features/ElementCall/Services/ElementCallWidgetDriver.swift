//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

private let logElementCallWidget = ScopedLog(.call)

enum ElementCallWidgetDriverError: Error {
    case failedBuildingCallURL
    case failedBuildingWidgetSettings
    case failedBuildingWidgetDriver
    case failedParsingCallURL
    case driverNotSetup
}

private struct ElementCallWidgetMessage: Codable {

    enum Direction: String, Codable {
        case fromWidget
        case toWidget
    }

    enum Action: String, Codable {
        case hangup = "im.vector.hangup"
        case close = "io.element.close"
        case mediaState = "io.element.device_mute"
    }

    struct Data: Codable {
        var audioEnabled: Bool?
        var videoEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case audioEnabled = "audio_enabled"
            case videoEnabled = "video_enabled"
        }
    }

    let direction: Direction
    let action: Action
    var data = Data()
    let widgetId: String
    var requestId = "widgetapi-\(UUID())"

    enum CodingKeys: String, CodingKey {
        case direction = "api"
        case action
        case data
        case widgetId
        case requestId
    }
}

final class ElementCallWidgetDriver: WidgetCapabilitiesProvider, @unchecked Sendable {

    let widgetID = UUID().uuidString

    var onMessageToWidget: (@Sendable (String) -> Void)?
    var onCallEnded: (@Sendable () -> Void)?
    var onMediaStateChanged: (@Sendable (_ audioEnabled: Bool, _ videoEnabled: Bool) -> Void)?

    private let room: Room
    private let deviceID: String
    private var widgetDriver: WidgetDriverAndHandle?

    init(room: Room, deviceID: String) {
        self.room = room
        self.deviceID = deviceID
    }

    func start(
        baseURL: URL,
        clientID: String,
        theme: String,
        voiceOnly: Bool = false
    ) async -> Result<URL, ElementCallWidgetDriverError> {
        let useEncryption = (try? await room.latestEncryptionState() == .encrypted) ?? false
        let intent = await room.zynaElementCallIntent(voiceOnly: voiceOnly)

        let widgetSettings: WidgetSettings
        do {
            widgetSettings = try newVirtualElementCallWidget(
                props: .init(
                    elementCallUrl: baseURL.absoluteString,
                    widgetId: widgetID,
                    parentUrl: nil,
                    fontScale: nil,
                    font: nil,
                    encryption: useEncryption ? .perParticipantKeys : .unencrypted,
                    posthogUserId: nil,
                    posthogApiHost: nil,
                    posthogApiKey: nil,
                    rageshakeSubmitUrl: nil,
                    sentryDsn: nil,
                    sentryEnvironment: nil
                ),
                config: .init(
                    intent: intent,
                    header: HeaderStyle.none,
                    confineToRoom: true,
                    controlledAudioDevices: false
                )
            )
        } catch {
            logElementCallWidget("Failed to build Element Call widget settings: \(error)")
            return .failure(.failedBuildingWidgetSettings)
        }

        let languageTag = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let urlString: String
        do {
            urlString = try await generateWebviewUrl(
                widgetSettings: widgetSettings,
                room: room,
                props: .init(
                    clientId: clientID,
                    languageTag: languageTag,
                    theme: theme
                )
            )
        } catch {
            logElementCallWidget("Failed to generate Element Call widget URL: \(error)")
            return .failure(.failedBuildingCallURL)
        }

        guard let url = URL(string: urlString) else {
            logElementCallWidget("Failed to parse Element Call widget URL: \(urlString)")
            return .failure(.failedParsingCallURL)
        }

        let widgetDriver: WidgetDriverAndHandle
        do {
            widgetDriver = try makeWidgetDriver(settings: widgetSettings)
        } catch {
            logElementCallWidget("Failed to build Element Call widget driver: \(error)")
            return .failure(.failedBuildingWidgetDriver)
        }

        self.widgetDriver = widgetDriver
        startReceivingMessages(from: widgetDriver)
        startRunningDriver(widgetDriver)

        return .success(url)
    }

    @discardableResult
    func handleMessage(_ message: String) async -> Result<Bool, ElementCallWidgetDriverError> {
        guard let widgetDriver else {
            return .failure(.driverNotSetup)
        }

        let result = await widgetDriver.handle.send(msg: message)
        handleMessageIfNeeded(message)
        return .success(result)
    }

    func acquireCapabilities(capabilities: WidgetCapabilities) -> WidgetCapabilities {
        getElementCallRequiredPermissions(ownUserId: room.ownUserId(), ownDeviceId: deviceID)
    }

    private func startReceivingMessages(from widgetDriver: WidgetDriverAndHandle) {
        Task.detached { [weak self] in
            while let receivedMessage = await widgetDriver.handle.recv() {
                logElementCallWidget("Received Element Call widget message: \(receivedMessage)")
                self?.onMessageToWidget?(receivedMessage)
                self?.handleMessageIfNeeded(receivedMessage)
            }
        }
    }

    private func startRunningDriver(_ widgetDriver: WidgetDriverAndHandle) {
        Task.detached { [weak self, room] in
            guard let self else { return }
            await widgetDriver.driver.run(room: room, capabilitiesProvider: self)
        }
    }

    private func handleMessageIfNeeded(_ message: String) {
        guard let data = message.data(using: .utf8) else {
            return
        }

        do {
            let widgetMessage = try JSONDecoder().decode(ElementCallWidgetMessage.self, from: data)
            guard widgetMessage.direction == .fromWidget else { return }

            switch widgetMessage.action {
            case .hangup:
                // Ignore hangup echoes; close/callEnded is the signal that dismisses the UI.
                break
            case .close:
                onCallEnded?()
            case .mediaState:
                guard let audioEnabled = widgetMessage.data.audioEnabled else {
                    logElementCallWidget("Ignored Element Call media state without audio data")
                    return
                }
                let videoEnabled = widgetMessage.data.videoEnabled ?? true
                onMediaStateChanged?(audioEnabled, videoEnabled)
            }
        } catch {
            logElementCallWidget("Ignored unsupported Element Call widget message: \(error)")
        }
    }
}

private extension Room {

    func zynaElementCallIntent(voiceOnly: Bool = false) async -> Intent {
        switch (hasActiveRoomCall(), await isDirect()) {
        case (true, true):
            return voiceOnly ? .joinExistingDmVoice : .joinExistingDm
        case (true, false):
            return .joinExisting
        case (false, true):
            return voiceOnly ? .startCallDmVoice : .startCallDm
        case (false, false):
            return .startCall
        }
    }
}
