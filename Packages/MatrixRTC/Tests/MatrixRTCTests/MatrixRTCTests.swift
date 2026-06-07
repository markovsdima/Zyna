import Testing
@testable import MatrixRTC

@Test func computesRtcBackendIdentity() {
    let identity = MatrixRTCMembershipIdentity(
        userId: "@alice:example.com",
        deviceId: "DEVICE123",
        memberId: "memberABC"
    )

    #expect(identity.rtcBackendIdentity == "J+T45tGruxc+HrUOqJJlyQSV33m728Cme4+vt8/SWrU")
}

@Test func encodesCallEncryptionKeysContent() throws {
    let content = MatrixRTCCallEncryptionKeysContent(
        keys: .init(index: 7, key: "base64-key"),
        member: .init(id: "member-id", claimedDeviceId: "DEVICEID"),
        roomId: "!room:example.org",
        sentTimestamp: 123_456
    )

    let decoded = try MatrixRTCCallEncryptionKeysContent(contentJSON: content.jsonString())

    #expect(decoded.keys.index == 7)
    #expect(decoded.keys.key == "base64-key")
    #expect(decoded.member.id == "member-id")
    #expect(decoded.member.claimedDeviceId == "DEVICEID")
    #expect(decoded.roomId == "!room:example.org")
    #expect(decoded.session == .matrixCallRoom)
    #expect(decoded.sentTimestamp == 123_456)
}

@Test func encodesCallNotificationContent() throws {
    let content = MatrixRTCCallNotificationContent(
        parentEventId: "$membership",
        notificationType: .ring,
        senderTimestamp: 123_456,
        callIntent: "audio"
    )

    let decoded = try MatrixRTCCallNotificationContent(contentJSON: content.jsonString())

    #expect(decoded.mentions == .roomWide)
    #expect(decoded.notificationType == .ring)
    #expect(decoded.relation == .reference(eventId: "$membership"))
    #expect(decoded.senderTimestamp == 123_456)
    #expect(decoded.lifetime == 30_000)
    #expect(decoded.callIntent == "audio")
}

@Test func encodesLegacyCallNotifyContent() throws {
    let content = MatrixRTCLegacyCallNotifyContent(
        slot: .matrixCallRoom,
        notificationType: .notification
    )

    let decoded = try MatrixRTCLegacyCallNotifyContent(contentJSON: content.jsonString())

    #expect(decoded.application == "m.call")
    #expect(decoded.mentions == .roomWide)
    #expect(decoded.notifyType == "notify")
    #expect(decoded.callId == "ROOM")
}

@Test func sendsCallEncryptionKeysToExactTargets() async throws {
    let client = FakeCustomToDeviceClient()
    let transport = MatrixRTCToDeviceKeyTransport(
        roomId: "!room:example.org",
        ownIdentity: .init(userId: "@alice:example.org", deviceId: "ALICEDEVICE", memberId: "alice-member"),
        client: client,
        sentTimestampProvider: { 123_456 },
        onReceivedKey: { _ in }
    )
    let targets = [
        MatrixRTCToDeviceTarget(userId: "@bob:example.org", deviceId: "BOBDEVICE"),
    ]

    let failures = try await transport.sendKey(keyBase64Encoded: "base64-key", index: 3, targets: targets)

    #expect(failures.isEmpty)
    #expect(client.sentEventType == MatrixRTCCallEncryptionKeysContent.eventType)
    #expect(client.sentTargets == targets)

    let sentContentJSON = try #require(client.sentContentJSON)
    let sentContent = try MatrixRTCCallEncryptionKeysContent(contentJSON: sentContentJSON)
    #expect(sentContent.keys == .init(index: 3, key: "base64-key"))
    #expect(sentContent.member == .init(id: "alice-member", claimedDeviceId: "ALICEDEVICE"))
    #expect(sentContent.roomId == "!room:example.org")
    #expect(sentContent.session == .matrixCallRoom)
    #expect(sentContent.sentTimestamp == 123_456)
}

@Test func receivesEncryptedCallEncryptionKeys() throws {
    let client = FakeCustomToDeviceClient()
    let receivedBox = ReceivedKeyBox()
    let transport = MatrixRTCToDeviceKeyTransport(
        roomId: "!room:example.org",
        ownIdentity: .init(userId: "@alice:example.org", deviceId: "ALICEDEVICE", memberId: "alice-member"),
        client: client,
        onReceivedKey: { result in
            receivedBox.result = result
        }
    )
    transport.start()

    #expect(client.listenerEventType == MatrixRTCCallEncryptionKeysContent.eventType)
    #expect(client.listenerEncryptedOnly == true)

    let content = MatrixRTCCallEncryptionKeysContent(
        keys: .init(index: 9, key: "remote-key"),
        member: .init(id: "bob-member", claimedDeviceId: "BOBDEVICE"),
        roomId: "!room:example.org",
        sentTimestamp: 654_321
    )
    client.emit(.init(
        eventType: MatrixRTCCallEncryptionKeysContent.eventType,
        sender: "@spoofed:example.org",
        contentJSON: try content.jsonString(),
        rawJSON: "{}",
        encryptionInfo: .init(
            sender: "@bob:example.org",
            senderDevice: "BOBDEVICE",
            senderCurve25519KeyBase64: "curve-key",
            senderVerified: true
        )
    ))

    let receivedResult = try #require(receivedBox.result)
    let received = try receivedResult.get()
    #expect(received.sender == "@bob:example.org")
    #expect(received.membership == .init(userId: "@bob:example.org", deviceId: "BOBDEVICE", memberId: "bob-member"))
    #expect(received.keyBase64Encoded == "remote-key")
    #expect(received.keyIndex == 9)
    #expect(received.sentTimestamp == 654_321)
    #expect(received.encryptionInfo?.senderVerified == true)
}

@Test func ignoresCallEncryptionKeysForOtherRooms() throws {
    let client = FakeCustomToDeviceClient()
    let receivedBox = ReceivedKeyBox()
    let transport = MatrixRTCToDeviceKeyTransport(
        roomId: "!room:example.org",
        ownIdentity: .init(userId: "@alice:example.org", deviceId: "ALICEDEVICE", memberId: "alice-member"),
        client: client,
        onReceivedKey: { result in
            receivedBox.result = result
        }
    )
    transport.start()

    let content = MatrixRTCCallEncryptionKeysContent(
        keys: .init(index: 1, key: "other-room-key"),
        member: .init(id: "bob-member", claimedDeviceId: "BOBDEVICE"),
        roomId: "!other:example.org",
        sentTimestamp: 123
    )
    client.emit(.init(
        eventType: MatrixRTCCallEncryptionKeysContent.eventType,
        sender: "@bob:example.org",
        contentJSON: try content.jsonString(),
        rawJSON: "{}",
        encryptionInfo: .init(
            sender: "@bob:example.org",
            senderDevice: "BOBDEVICE",
            senderCurve25519KeyBase64: "curve-key",
            senderVerified: true
        )
    ))

    #expect(receivedBox.result == nil)
}

@Test func fallsBackToClaimedDeviceMemberIdWhenMissing() throws {
    let client = FakeCustomToDeviceClient()
    let receivedBox = ReceivedKeyBox()
    let transport = MatrixRTCToDeviceKeyTransport(
        roomId: "!room:example.org",
        ownIdentity: .init(userId: "@alice:example.org", deviceId: "ALICEDEVICE", memberId: "alice-member"),
        client: client,
        onReceivedKey: { result in
            receivedBox.result = result
        }
    )
    transport.start()

    let content = MatrixRTCCallEncryptionKeysContent(
        keys: .init(index: 2, key: "fallback-key"),
        member: .init(id: nil, claimedDeviceId: "BOBDEVICE"),
        roomId: "!room:example.org",
        sentTimestamp: 456
    )
    client.emit(.init(
        eventType: MatrixRTCCallEncryptionKeysContent.eventType,
        sender: "@spoofed:example.org",
        contentJSON: try content.jsonString(),
        rawJSON: "{}",
        encryptionInfo: .init(
            sender: "@bob:example.org",
            senderDevice: "BOBDEVICE",
            senderCurve25519KeyBase64: "curve-key",
            senderVerified: true
        )
    ))

    let receivedResult = try #require(receivedBox.result)
    let received = try receivedResult.get()
    #expect(received.membership.memberId == "@bob:example.org:BOBDEVICE")
}

final class ReceivedKeyBox: @unchecked Sendable {
    var result: Result<MatrixRTCReceivedCallEncryptionKey, Error>?
}

final class FakeCustomToDeviceClient: MatrixRTCCustomToDeviceEncrypting, @unchecked Sendable {
    var sentEventType: String?
    var sentTargets: [MatrixRTCToDeviceTarget]?
    var sentContentJSON: String?
    var sentTargetsHistory: [[MatrixRTCToDeviceTarget]] = []
    var sentContentJSONHistory: [String] = []
    var sendCount = 0
    var sendFailures: [MatrixRTCCustomToDeviceSendFailure] = []

    var listenerEventType: String?
    var listenerEncryptedOnly: Bool?
    var listener: (@Sendable (MatrixRTCCustomToDeviceEvent) -> Void)?

    func encryptAndSendRawToDevice(
        eventType: String,
        targets: [MatrixRTCToDeviceTarget],
        contentJSON: String
    ) async throws -> [MatrixRTCCustomToDeviceSendFailure] {
        sendCount += 1
        sentEventType = eventType
        sentTargets = targets
        sentContentJSON = contentJSON
        sentTargetsHistory.append(targets)
        sentContentJSONHistory.append(contentJSON)
        return sendFailures
    }

    func addCustomToDeviceEventListener(
        eventType: String,
        encryptedOnly: Bool,
        listener: @escaping @Sendable (MatrixRTCCustomToDeviceEvent) -> Void
    ) -> any MatrixRTCCancellable {
        listenerEventType = eventType
        listenerEncryptedOnly = encryptedOnly
        self.listener = listener
        return MatrixRTCNoopCancellable()
    }

    func emit(_ event: MatrixRTCCustomToDeviceEvent) {
        listener?(event)
    }
}
