import Testing
@testable import MatrixRTC

@Test func sharesOutboundMediaKeyWithActiveMemberships() async throws {
    let client = FakeCustomToDeviceClient()
    let ownMembership = try legacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 1_000
    )
    let bobMembership = try legacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 2_000
    )
    let keyBox = MediaKeyEventBox()
    let transport = MatrixRTCToDeviceKeyTransport(
        roomId: "!room:example.org",
        ownIdentity: ownMembership.identity,
        client: client,
        onReceivedKey: { _ in }
    )
    let manager = MatrixRTCMediaKeyManager(
        ownMembership: ownMembership,
        memberships: [ownMembership, bobMembership],
        transport: transport,
        keyGenerator: StaticMediaKeyGenerator(key: "own-key"),
        onKeyChanged: { event in
            keyBox.events.append(event)
        }
    )

    let result = try await manager.shareCurrentKey()

    #expect(result.failures.isEmpty)
    #expect(result.sharedWith == [.init(userId: "@bob:example.org", deviceId: "BOBDEVICE")])
    #expect(client.sentEventType == MatrixRTCCallEncryptionKeysContent.eventType)
    #expect(client.sentTargets == [.init(userId: "@bob:example.org", deviceId: "BOBDEVICE")])

    let contentJSON = try #require(client.sentContentJSON)
    let content = try MatrixRTCCallEncryptionKeysContent(contentJSON: contentJSON)
    #expect(content.keys == .init(index: 0, key: "own-key"))
    #expect(content.member == .init(id: "@alice:example.org:ALICEDEVICE", claimedDeviceId: "ALICEDEVICE"))
    #expect(content.roomId == "!room:example.org")

    let ownKey = try #require(keyBox.events.first?.key)
    #expect(ownKey.keyBase64Encoded == "own-key")
    #expect(ownKey.keyIndex == 0)
    #expect(ownKey.membership == ownMembership.identity)
    #expect(ownKey.rtcBackendIdentity == "@alice:example.org:ALICEDEVICE")
}

@Test func doesNotReshareOutboundMediaKeyToSameMembership() async throws {
    let client = FakeCustomToDeviceClient()
    let ownMembership = try legacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 1_000
    )
    let bobMembership = try legacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 2_000
    )
    let transport = MatrixRTCToDeviceKeyTransport(
        roomId: "!room:example.org",
        ownIdentity: ownMembership.identity,
        client: client,
        onReceivedKey: { _ in }
    )
    let manager = MatrixRTCMediaKeyManager(
        ownMembership: ownMembership,
        memberships: [ownMembership, bobMembership],
        transport: transport,
        keyGenerator: StaticMediaKeyGenerator(key: "own-key"),
        onKeyChanged: { _ in }
    )

    _ = try await manager.shareCurrentKey()
    let secondResult = try await manager.shareCurrentKey()

    #expect(secondResult.sharedWith.isEmpty)
    #expect(client.sendCount == 1)
}

@Test func storesInboundMediaKeyWithMembershipBackendIdentity() throws {
    let client = FakeCustomToDeviceClient()
    let ownMembership = try legacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 1_000
    )
    let bobMembership = try legacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 2_000
    )
    let keyBox = MediaKeyEventBox()
    let manager = MatrixRTCMediaKeyManager(
        ownMembership: ownMembership,
        memberships: [ownMembership, bobMembership],
        transport: .init(
            roomId: "!room:example.org",
            ownIdentity: ownMembership.identity,
            client: client,
            onReceivedKey: { _ in }
        ),
        keyGenerator: StaticMediaKeyGenerator(key: "own-key"),
        onKeyChanged: { event in
            keyBox.events.append(event)
        }
    )

    manager.handleReceivedKey(.init(
        sender: "@bob:example.org",
        membership: bobMembership.identity,
        keyBase64Encoded: "bob-key",
        keyIndex: 7,
        sentTimestamp: 12_345,
        encryptionInfo: nil
    ))

    let changedKey = try #require(keyBox.events.first?.key)
    #expect(changedKey.keyBase64Encoded == "bob-key")
    #expect(changedKey.keyIndex == 7)
    #expect(changedKey.membership == bobMembership.identity)
    #expect(changedKey.rtcBackendIdentity == "@bob:example.org:BOBDEVICE")

    let storedKeys = manager.encryptionKeys()[.init(membership: bobMembership.identity)]
    #expect(storedKeys?.map(\.keyBase64Encoded) == ["bob-key"])
}

@Test func matchesInboundMediaKeyByUserDeviceWhenMemberIdDiffers() throws {
    let client = FakeCustomToDeviceClient()
    let ownMembership = try legacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 1_000
    )
    let bobMembership = try legacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 2_000
    )
    let receivedMembership = MatrixRTCMembershipIdentity(
        userId: "@bob:example.org",
        deviceId: "BOBDEVICE",
        memberId: "element-call-member-id"
    )
    let keyBox = MediaKeyEventBox()
    let manager = MatrixRTCMediaKeyManager(
        ownMembership: ownMembership,
        memberships: [ownMembership, bobMembership],
        transport: .init(
            roomId: "!room:example.org",
            ownIdentity: ownMembership.identity,
            client: client,
            onReceivedKey: { _ in }
        ),
        keyGenerator: StaticMediaKeyGenerator(key: "own-key"),
        onKeyChanged: { event in
            keyBox.events.append(event)
        }
    )

    manager.handleReceivedKey(.init(
        sender: "@bob:example.org",
        membership: receivedMembership,
        keyBase64Encoded: "bob-key",
        keyIndex: 8,
        sentTimestamp: 12_345,
        encryptionInfo: nil
    ))

    let changedKey = try #require(keyBox.events.first?.key)
    #expect(changedKey.keyBase64Encoded == "bob-key")
    #expect(changedKey.keyIndex == 8)
    #expect(changedKey.membership == bobMembership.identity)
    #expect(changedKey.rtcBackendIdentity == "@bob:example.org:BOBDEVICE")

    let storedKeys = manager.encryptionKeys()[.init(membership: bobMembership.identity)]
    #expect(storedKeys?.map(\.keyBase64Encoded) == ["bob-key"])
}

@Test func handlesInboundMediaKeysReceivedThroughTransport() throws {
    let client = FakeCustomToDeviceClient()
    let ownMembership = try legacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 1_000
    )
    let bobMembership = try legacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 2_000
    )
    let keyBox = MediaKeyEventBox()
    let manager = MatrixRTCMediaKeyManager(
        ownMembership: ownMembership,
        memberships: [ownMembership, bobMembership],
        transport: .init(
            roomId: "!room:example.org",
            ownIdentity: ownMembership.identity,
            client: client
        ),
        keyGenerator: StaticMediaKeyGenerator(key: "own-key"),
        onKeyChanged: { event in
            keyBox.events.append(event)
        }
    )
    manager.start()

    let content = MatrixRTCCallEncryptionKeysContent(
        keys: .init(index: 5, key: "bob-key"),
        member: .init(id: bobMembership.memberId, claimedDeviceId: "BOBDEVICE"),
        roomId: "!room:example.org",
        sentTimestamp: 123_456
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

    #expect(client.listenerEventType == MatrixRTCCallEncryptionKeysContent.eventType)
    #expect(client.listenerEncryptedOnly == true)

    let changedKey = try #require(keyBox.events.first?.key)
    #expect(changedKey.keyBase64Encoded == "bob-key")
    #expect(changedKey.keyIndex == 5)
    #expect(changedKey.membership == bobMembership.identity)
    #expect(changedKey.rtcBackendIdentity == "@bob:example.org:BOBDEVICE")
}

@Test func queuesInboundMediaKeyUntilMatchingMembershipArrives() throws {
    let client = FakeCustomToDeviceClient()
    let ownMembership = try legacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 1_000
    )
    let bobMembership = try legacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 2_000
    )
    let keyBox = MediaKeyEventBox()
    let manager = MatrixRTCMediaKeyManager(
        ownMembership: ownMembership,
        memberships: [ownMembership],
        transport: .init(
            roomId: "!room:example.org",
            ownIdentity: ownMembership.identity,
            client: client,
            onReceivedKey: { _ in }
        ),
        keyGenerator: StaticMediaKeyGenerator(key: "own-key"),
        onKeyChanged: { event in
            keyBox.events.append(event)
        }
    )

    manager.handleReceivedKey(.init(
        sender: "@bob:example.org",
        membership: bobMembership.identity,
        keyBase64Encoded: "bob-key",
        keyIndex: 3,
        sentTimestamp: nil,
        encryptionInfo: nil
    ))
    #expect(keyBox.events.isEmpty)

    manager.updateMemberships([ownMembership, bobMembership])

    let changedKey = try #require(keyBox.events.first?.key)
    #expect(changedKey.keyBase64Encoded == "bob-key")
    #expect(changedKey.rtcBackendIdentity == "@bob:example.org:BOBDEVICE")
}

private struct StaticMediaKeyGenerator: MatrixRTCMediaKeyGenerating {
    let key: String

    func generateMediaKeyBase64Encoded() -> String {
        key
    }
}

private final class MediaKeyEventBox: @unchecked Sendable {
    var events: [MatrixRTCMediaKeyChangedEvent] = []
}

private func legacyMembership(
    eventId: String,
    sender: String,
    deviceId: String,
    createdTimestamp: Int64
) throws -> MatrixRTCCallMembership {
    try MatrixRTCCallMembershipParser.parse(event: .init(
        eventId: eventId,
        eventType: MatrixRTCRawMembershipEvent.legacyCallMemberEventType,
        stateKey: "_\(sender)_\(deviceId)_m.call",
        sender: sender,
        originServerTimestamp: createdTimestamp,
        contentJSON: """
        {
          "application": "m.call",
          "call_id": "",
          "device_id": "\(deviceId)",
          "focus_active": {
            "type": "livekit",
            "focus_selection": "oldest_membership"
          },
          "foci_preferred": [],
          "created_ts": \(createdTimestamp),
          "expires": 50000
        }
        """
    ))
}
