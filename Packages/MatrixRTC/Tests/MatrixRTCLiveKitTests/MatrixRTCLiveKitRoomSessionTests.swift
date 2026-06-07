import Foundation
import LiveKit
import MatrixRTC
@testable import MatrixRTCLiveKit
import Testing

@Test func connectsLiveKitRoomWithMatrixRTCEncryptionOptions() async throws {
    let box = RoomSessionTestBox()
    let keyProvider = MatrixRTCLiveKitKeyProvider()
    let eventBox = RoomSessionEventBox()
    let session = MatrixRTCLiveKitRoomSession(
        keyProvider: keyProvider,
        connectOptions: ConnectOptions(autoSubscribe: false),
        roomFactory: { roomOptions in
            box.roomOptions = roomOptions
            return box.room
        },
        onEvent: { event in
            eventBox.append(event)
        }
    )

    try await session.connect(sfuConfig: sfuConfig)

    #expect(session.state == .connected)
    #expect(box.room.connectCalls.count == 1)
    #expect(box.room.connectCalls[0].url == "wss://livekit.example.org")
    #expect(box.room.connectCalls[0].token == "jwt-token")
    #expect(box.room.connectCalls[0].connectOptions?.autoSubscribe == false)
    #expect(box.room.connectCalls[0].roomOptions === session.roomOptions)
    #expect(box.roomOptions?.encryptionOptions?.keyProvider === keyProvider.baseKeyProvider)
    #expect(box.roomOptions?.encryptionOptions?.encryptionType == .gcm)
    #expect(box.room.addedDelegates.count == 1)
    #expect(eventBox.events.isEmpty)
}

@Test func appliesMediaKeysToLiveKitKeyProvider() throws {
    let eventBox = RoomSessionEventBox()
    let session = MatrixRTCLiveKitRoomSession(onEvent: { event in
        eventBox.append(event)
    })
    let rawKey = Data((0..<16).map(UInt8.init))
    let mediaKey = MatrixRTCMediaKey(
        keyBase64Encoded: rawKey.base64EncodedString(),
        keyIndex: 3,
        membership: membership,
        rtcBackendIdentity: membership.legacyRTCBackendIdentity
    )

    let liveKitKey = try session.handleMediaKeyChanged(.init(key: mediaKey))

    #expect(liveKitKey.rawKey == rawKey)
    #expect(liveKitKey.participantId == membership.legacyRTCBackendIdentity)

    let exportedKey = try #require(session.keyProvider.baseKeyProvider.exportKey(
        participantId: membership.legacyRTCBackendIdentity,
        index: 3
    ))
    #expect(exportedKey == rawKey)
    #expect(eventBox.events == [
        .mediaKeyApplied(keyIndex: 3, participantId: membership.legacyRTCBackendIdentity)
    ])
}

@Test func publishesAudioWhenRequested() async throws {
    let box = RoomSessionTestBox()
    let session = MatrixRTCLiveKitRoomSession(roomFactory: { _ in box.room })

    try await session.connect(sfuConfig: sfuConfig, publishAudio: true)

    #expect(session.state == .connected)
    #expect(session.isMicrophoneEnabled)
    #expect(box.room.microphoneEnabledCalls == [true])
    #expect(box.room.disconnectCalls == 0)
}

@Test func disconnectsWhenInitialAudioPublishFails() async throws {
    let box = RoomSessionTestBox()
    box.room.microphoneError = MatrixRTCLiveKitRoomSessionError.notConnected
    let session = MatrixRTCLiveKitRoomSession(roomFactory: { _ in box.room })

    await #expect(throws: MatrixRTCLiveKitRoomSessionError.notConnected) {
        try await session.connect(sfuConfig: sfuConfig, publishAudio: true)
    }

    #expect(session.state == .disconnected)
    #expect(session.isMicrophoneEnabled == false)
    #expect(box.room.connectCalls.count == 1)
    #expect(box.room.disconnectCalls == 1)
}

@Test func rejectsMicrophoneChangesBeforeConnect() async throws {
    let session = MatrixRTCLiveKitRoomSession()

    await #expect(throws: MatrixRTCLiveKitRoomSessionError.notConnected) {
        try await session.setMicrophoneEnabled(true)
    }
}

@Test func togglesCameraAfterConnect() async throws {
    let box = RoomSessionTestBox()
    let session = MatrixRTCLiveKitRoomSession(roomFactory: { _ in box.room })

    try await session.connect(sfuConfig: sfuConfig)
    try await session.setCameraEnabled(true)

    #expect(session.isCameraEnabled)

    try await session.setCameraEnabled(false)

    #expect(session.isCameraEnabled == false)
    #expect(box.room.cameraEnabledCalls == [true, false])
}

@Test func rejectsCameraChangesBeforeConnect() async throws {
    let session = MatrixRTCLiveKitRoomSession()

    await #expect(throws: MatrixRTCLiveKitRoomSessionError.notConnected) {
        try await session.setCameraEnabled(true)
    }
}

@Test func switchesCameraPositionAfterCameraEnabled() async throws {
    let box = RoomSessionTestBox()
    let session = MatrixRTCLiveKitRoomSession(roomFactory: { _ in box.room })

    try await session.connect(sfuConfig: sfuConfig)
    try await session.setCameraEnabled(true)

    let didSwitch = try await session.switchCameraPosition()

    #expect(didSwitch)
    #expect(box.room.cameraSwitchCalls == 1)
}

@Test func rejectsCameraPositionSwitchBeforeCameraEnabled() async throws {
    let box = RoomSessionTestBox()
    let session = MatrixRTCLiveKitRoomSession(roomFactory: { _ in box.room })

    try await session.connect(sfuConfig: sfuConfig)

    await #expect(throws: MatrixRTCLiveKitRoomSessionError.cameraNotEnabled) {
        try await session.switchCameraPosition()
    }
}

private let sfuConfig = MatrixRTCLiveKitSFUConfig(
    url: "wss://livekit.example.org",
    jwt: "jwt-token",
    liveKitAlias: "livekit-alias",
    liveKitIdentity: "@alice:example.org:ALICEDEVICE"
)

private let membership = MatrixRTCMembershipIdentity(
    userId: "@alice:example.org",
    deviceId: "ALICEDEVICE",
    memberId: "@alice:example.org:ALICEDEVICE"
)

private final class RoomSessionTestBox: @unchecked Sendable {
    let room = MockLiveKitRoom()
    var roomOptions: RoomOptions?
}

private final class RoomSessionEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [MatrixRTCLiveKitRoomSessionEvent] = []

    var events: [MatrixRTCLiveKitRoomSessionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: MatrixRTCLiveKitRoomSessionEvent) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(event)
    }
}

private final class MockLiveKitRoom: MatrixRTCLiveKitRoomControlling, @unchecked Sendable {
    struct ConnectCall {
        let url: String
        let token: String
        let connectOptions: ConnectOptions?
        let roomOptions: RoomOptions?
    }

    var connectCalls: [ConnectCall] = []
    var disconnectCalls = 0
    var microphoneEnabledCalls: [Bool] = []
    var cameraEnabledCalls: [Bool] = []
    var cameraSwitchCalls = 0
    var cameraSwitchResult = true
    var addedDelegates: [RoomDelegate] = []
    var removedDelegates: [RoomDelegate] = []
    var connectError: Error?
    var microphoneError: Error?
    var cameraError: Error?
    var cameraSwitchError: Error?

    func connect(
        url: String,
        token: String,
        connectOptions: ConnectOptions?,
        roomOptions: RoomOptions?
    ) async throws {
        if let connectError {
            throw connectError
        }

        connectCalls.append(.init(
            url: url,
            token: token,
            connectOptions: connectOptions,
            roomOptions: roomOptions
        ))
    }

    func disconnect() async {
        disconnectCalls += 1
    }

    func setMicrophone(enabled: Bool) async throws {
        if let microphoneError {
            throw microphoneError
        }

        microphoneEnabledCalls.append(enabled)
    }

    func setCamera(enabled: Bool) async throws {
        if let cameraError {
            throw cameraError
        }

        cameraEnabledCalls.append(enabled)
    }

    func switchCameraPosition() async throws -> Bool {
        if let cameraSwitchError {
            throw cameraSwitchError
        }

        cameraSwitchCalls += 1
        return cameraSwitchResult
    }

    func add(delegate: RoomDelegate) {
        addedDelegates.append(delegate)
    }

    func remove(delegate: RoomDelegate) {
        removedDelegates.append(delegate)
    }
}
