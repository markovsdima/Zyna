import Foundation
import LiveKit
import MatrixRTC

public enum MatrixRTCLiveKitRoomSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
}

public enum MatrixRTCLiveKitRoomSessionError: Error, Equatable {
    case alreadyConnecting
    case alreadyConnected
    case notConnected
}

public struct MatrixRTCLiveKitParticipantInfo: Equatable, Sendable {
    public let identity: String?
    public let sid: String?

    public init(identity: String?, sid: String?) {
        self.identity = identity
        self.sid = sid
    }
}

public struct MatrixRTCLiveKitTrackPublicationInfo: Equatable, Sendable {
    public let sid: String
    public let name: String
    public let kind: String
    public let source: String
    public let isMuted: Bool
    public let isSubscribed: Bool

    public init(
        sid: String,
        name: String,
        kind: String,
        source: String,
        isMuted: Bool,
        isSubscribed: Bool
    ) {
        self.sid = sid
        self.name = name
        self.kind = kind
        self.source = source
        self.isMuted = isMuted
        self.isSubscribed = isSubscribed
    }
}

public enum MatrixRTCLiveKitRoomSessionEvent: Equatable, Sendable {
    case connectionStateChanged(state: String, previousState: String)
    case connected
    case disconnected(error: String?)
    case failedToConnect(error: String?)
    case localTrackPublished(MatrixRTCLiveKitTrackPublicationInfo)
    case localTrackUnpublished(MatrixRTCLiveKitTrackPublicationInfo)
    case localTrackSubscribedByRemote(MatrixRTCLiveKitTrackPublicationInfo)
    case remoteParticipantJoined(MatrixRTCLiveKitParticipantInfo)
    case remoteParticipantLeft(MatrixRTCLiveKitParticipantInfo)
    case remoteTrackPublished(participant: MatrixRTCLiveKitParticipantInfo, publication: MatrixRTCLiveKitTrackPublicationInfo)
    case remoteTrackUnpublished(participant: MatrixRTCLiveKitParticipantInfo, publication: MatrixRTCLiveKitTrackPublicationInfo)
    case remoteTrackSubscribed(participant: MatrixRTCLiveKitParticipantInfo, publication: MatrixRTCLiveKitTrackPublicationInfo)
    case remoteTrackUnsubscribed(participant: MatrixRTCLiveKitParticipantInfo, publication: MatrixRTCLiveKitTrackPublicationInfo)
    case remoteTrackSubscriptionFailed(participant: MatrixRTCLiveKitParticipantInfo, trackSid: String, error: String)
    case trackMutedChanged(participant: MatrixRTCLiveKitParticipantInfo, publication: MatrixRTCLiveKitTrackPublicationInfo, isMuted: Bool)
    case remoteTrackStreamStateChanged(participant: MatrixRTCLiveKitParticipantInfo, publication: MatrixRTCLiveKitTrackPublicationInfo, state: String)
    case trackE2EEStateChanged(publication: MatrixRTCLiveKitTrackPublicationInfo, state: String)
    case mediaKeyApplied(keyIndex: Int32, participantId: String)
}

public protocol MatrixRTCLiveKitRoomControlling: AnyObject, Sendable {
    func connect(
        url: String,
        token: String,
        connectOptions: ConnectOptions?,
        roomOptions: RoomOptions?
    ) async throws

    func disconnect() async
    func setMicrophone(enabled: Bool) async throws
    func add(delegate: RoomDelegate)
    func remove(delegate: RoomDelegate)
}

extension Room: MatrixRTCLiveKitRoomControlling {
    public func setMicrophone(enabled: Bool) async throws {
        try await localParticipant.setMicrophone(enabled: enabled)
    }
}

public final class MatrixRTCLiveKitRoomSession: @unchecked Sendable {
    public typealias RoomOptionsFactory = @Sendable (EncryptionOptions) -> RoomOptions
    public typealias RoomFactory = @Sendable (RoomOptions) -> any MatrixRTCLiveKitRoomControlling
    public typealias ErrorHandler = @Sendable (Error) -> Void
    public typealias EventHandler = @Sendable (MatrixRTCLiveKitRoomSessionEvent) -> Void

    public let keyProvider: MatrixRTCLiveKitKeyProvider
    public let connectOptions: ConnectOptions
    public let roomOptions: RoomOptions
    public let room: any MatrixRTCLiveKitRoomControlling

    private let eventHandler: EventHandler?
    private let roomObserver: MatrixRTCLiveKitRoomObserver
    private let lock = NSLock()
    private var _state: MatrixRTCLiveKitRoomSessionState = .idle
    private var _isMicrophoneEnabled = false

    public var state: MatrixRTCLiveKitRoomSessionState {
        withLock { _state }
    }

    public var isMicrophoneEnabled: Bool {
        withLock { _isMicrophoneEnabled }
    }

    public init(
        keyProvider: MatrixRTCLiveKitKeyProvider = MatrixRTCLiveKitKeyProvider(),
        connectOptions: ConnectOptions = ConnectOptions(),
        roomOptionsFactory: RoomOptionsFactory = {
            RoomOptions(encryptionOptions: $0)
        },
        roomFactory: RoomFactory = {
            Room(roomOptions: $0)
        },
        onEvent: EventHandler? = nil
    ) {
        self.keyProvider = keyProvider
        self.connectOptions = connectOptions
        self.roomOptions = roomOptionsFactory(keyProvider.liveKitEncryptionOptions())
        self.room = roomFactory(roomOptions)
        self.eventHandler = onEvent
        self.roomObserver = MatrixRTCLiveKitRoomObserver(onEvent: onEvent)
        self.room.add(delegate: roomObserver)
    }

    deinit {
        room.remove(delegate: roomObserver)
    }

    public func connect(
        sfuConfig: MatrixRTCLiveKitSFUConfig,
        publishAudio: Bool = false
    ) async throws {
        try markConnecting()

        do {
            try await room.connect(
                url: sfuConfig.url,
                token: sfuConfig.jwt,
                connectOptions: connectOptions,
                roomOptions: roomOptions
            )
            setState(.connected)

            if publishAudio {
                do {
                    try await setMicrophoneEnabled(true)
                } catch {
                    await disconnect()
                    throw error
                }
            }
        } catch {
            setState(.disconnected)
            throw error
        }
    }

    public func disconnect() async {
        await room.disconnect()
        withLock {
            _isMicrophoneEnabled = false
            _state = .disconnected
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard state == .connected else {
            throw MatrixRTCLiveKitRoomSessionError.notConnected
        }

        try await room.setMicrophone(enabled: enabled)
        withLock {
            _isMicrophoneEnabled = enabled
        }
    }

    @discardableResult
    public func handleMediaKeyChanged(
        _ event: MatrixRTCMediaKeyChangedEvent
    ) throws -> MatrixRTCLiveKitMediaKey {
        let liveKitKey = try keyProvider.apply(event)
        eventHandler?(.mediaKeyApplied(
            keyIndex: liveKitKey.keyIndex,
            participantId: liveKitKey.participantId
        ))
        return liveKitKey
    }

    public func keyChangedHandler(onError: ErrorHandler? = nil) -> MatrixRTCMediaKeyManager.KeyChangedHandler {
        { [weak self] event in
            do {
                guard let self else { return }
                try self.handleMediaKeyChanged(event)
            } catch {
                onError?(error)
            }
        }
    }
}

private extension MatrixRTCLiveKitRoomSession {
    func markConnecting() throws {
        try withLock {
            switch _state {
            case .connecting:
                throw MatrixRTCLiveKitRoomSessionError.alreadyConnecting
            case .connected:
                throw MatrixRTCLiveKitRoomSessionError.alreadyConnected
            case .idle, .disconnected:
                _state = .connecting
            }
        }
    }

    func setState(_ state: MatrixRTCLiveKitRoomSessionState) {
        withLock {
            _state = state
        }
    }

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class MatrixRTCLiveKitRoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    private let onEvent: MatrixRTCLiveKitRoomSession.EventHandler?

    init(onEvent: MatrixRTCLiveKitRoomSession.EventHandler?) {
        self.onEvent = onEvent
    }

    func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        onEvent?(.connectionStateChanged(
            state: String(describing: connectionState),
            previousState: String(describing: oldConnectionState)
        ))
    }

    func roomDidConnect(_ room: Room) {
        onEvent?(.connected)
    }

    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        onEvent?(.failedToConnect(error: error.map(String.init(describing:))))
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        onEvent?(.disconnected(error: error.map(String.init(describing:))))
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        onEvent?(.remoteParticipantJoined(.init(participant: participant)))
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        onEvent?(.remoteParticipantLeft(.init(participant: participant)))
    }

    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        onEvent?(.localTrackPublished(.init(publication: publication)))
    }

    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        onEvent?(.localTrackUnpublished(.init(publication: publication)))
    }

    func room(_ room: Room, participant: LocalParticipant, remoteDidSubscribeTrack publication: LocalTrackPublication) {
        onEvent?(.localTrackSubscribedByRemote(.init(publication: publication)))
    }

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        onEvent?(.remoteTrackPublished(
            participant: .init(participant: participant),
            publication: .init(publication: publication)
        ))
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        onEvent?(.remoteTrackUnpublished(
            participant: .init(participant: participant),
            publication: .init(publication: publication)
        ))
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        onEvent?(.remoteTrackSubscribed(
            participant: .init(participant: participant),
            publication: .init(publication: publication)
        ))
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        onEvent?(.remoteTrackUnsubscribed(
            participant: .init(participant: participant),
            publication: .init(publication: publication)
        ))
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant,
        didFailToSubscribeTrackWithSid trackSid: Track.Sid,
        error: LiveKitError
    ) {
        onEvent?(.remoteTrackSubscriptionFailed(
            participant: .init(participant: participant),
            trackSid: trackSid.stringValue,
            error: String(describing: error)
        ))
    }

    func room(
        _ room: Room,
        participant: Participant,
        trackPublication: TrackPublication,
        didUpdateIsMuted isMuted: Bool
    ) {
        onEvent?(.trackMutedChanged(
            participant: .init(participant: participant),
            publication: .init(publication: trackPublication),
            isMuted: isMuted
        ))
    }

    func room(
        _ room: Room,
        participant: RemoteParticipant,
        trackPublication: RemoteTrackPublication,
        didUpdateStreamState streamState: StreamState
    ) {
        onEvent?(.remoteTrackStreamStateChanged(
            participant: .init(participant: participant),
            publication: .init(publication: trackPublication),
            state: String(describing: streamState)
        ))
    }

    func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        onEvent?(.trackE2EEStateChanged(
            publication: .init(publication: trackPublication),
            state: state.toString()
        ))
    }
}

private extension MatrixRTCLiveKitParticipantInfo {
    init(participant: Participant) {
        self.init(
            identity: participant.identity?.stringValue,
            sid: participant.sid?.stringValue
        )
    }
}

private extension MatrixRTCLiveKitTrackPublicationInfo {
    init(publication: TrackPublication) {
        self.init(
            sid: publication.sid.stringValue,
            name: publication.name,
            kind: String(describing: publication.kind),
            source: String(describing: publication.source),
            isMuted: publication.isMuted,
            isSubscribed: publication.isSubscribed
        )
    }
}
