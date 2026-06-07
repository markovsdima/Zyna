import Foundation
import LiveKit
import MatrixRTC
@testable import MatrixRTCLiveKit
import Testing

@Test func connectsLiveKitRoomWithMatrixRTCEncryptionOptions() async throws {
    let box = RoomSessionTestBox()
    let keyProvider = MatrixRTCLiveKitKeyProvider()
    let session = MatrixRTCLiveKitRoomSession(
        keyProvider: keyProvider,
        connectOptions: ConnectOptions(autoSubscribe: false),
        roomFactory: { roomOptions in
            box.roomOptions = roomOptions
            return box.room
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
}

@Test func appliesMediaKeysToLiveKitKeyProvider() throws {
    let session = MatrixRTCLiveKitRoomSession()
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
    var connectError: Error?
    var microphoneError: Error?

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
}
