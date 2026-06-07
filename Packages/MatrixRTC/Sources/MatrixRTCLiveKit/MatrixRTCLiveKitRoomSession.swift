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

public protocol MatrixRTCLiveKitRoomControlling: AnyObject, Sendable {
    func connect(
        url: String,
        token: String,
        connectOptions: ConnectOptions?,
        roomOptions: RoomOptions?
    ) async throws

    func disconnect() async
    func setMicrophone(enabled: Bool) async throws
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

    public let keyProvider: MatrixRTCLiveKitKeyProvider
    public let connectOptions: ConnectOptions
    public let roomOptions: RoomOptions
    public let room: any MatrixRTCLiveKitRoomControlling

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
        }
    ) {
        self.keyProvider = keyProvider
        self.connectOptions = connectOptions
        self.roomOptions = roomOptionsFactory(keyProvider.liveKitEncryptionOptions())
        self.room = roomFactory(roomOptions)
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
        try keyProvider.apply(event)
    }

    public func keyChangedHandler(onError: ErrorHandler? = nil) -> MatrixRTCMediaKeyManager.KeyChangedHandler {
        { [weak self] event in
            do {
                try self?.handleMediaKeyChanged(event)
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
