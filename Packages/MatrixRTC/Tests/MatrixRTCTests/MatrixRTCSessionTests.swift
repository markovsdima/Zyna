import Testing
@testable import MatrixRTC

@Test func joinsSessionAndSharesInitialMediaKey() async throws {
    let membershipClient = FakeSessionMembershipClient()
    let toDeviceClient = FakeCustomToDeviceClient()
    let ownMembership = sessionLegacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 10_000
    )
    let bobMembership = sessionLegacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 20_000
    )
    membershipClient.publishResult = ownMembership
    membershipClient.activeMembershipResponses = [[bobMembership]]
    let keyBox = SessionMediaKeyEventBox()

    let session = MatrixRTCSession(
        configuration: .init(
            fociPreferred: [.liveKit(serviceURL: "https://livekit.example.org")],
            callIntent: "m.audio"
        ),
        membershipClient: membershipClient,
        keyTransportFactory: { identity in
            MatrixRTCToDeviceKeyTransport(
                roomId: "!room:example.org",
                ownIdentity: identity,
                client: toDeviceClient
            )
        },
        keyGenerator: StaticSessionMediaKeyGenerator(key: "own-key"),
        timestampProvider: { 10_000 },
        onKeyChanged: { event in
            keyBox.events.append(event)
        }
    )

    let result = try await session.join()

    #expect(session.state == .joined)
    #expect(result.ownMembership == ownMembership)
    #expect(result.memberships.map(\.identity) == [ownMembership.identity, bobMembership.identity])
    #expect(result.keyShareResult.sharedWith == [.init(userId: "@bob:example.org", deviceId: "BOBDEVICE")])

    #expect(membershipClient.publishCount == 1)
    #expect(membershipClient.publishedFociPreferred == [.liveKit(serviceURL: "https://livekit.example.org")])
    #expect(membershipClient.publishedCreatedTimestamp == 10_000)
    #expect(membershipClient.publishedCallIntent == "m.audio")
    #expect(membershipClient.loadCount == 1)

    #expect(toDeviceClient.listenerEventType == MatrixRTCCallEncryptionKeysContent.eventType)
    #expect(toDeviceClient.listenerEncryptedOnly == true)
    #expect(toDeviceClient.sentTargets == [.init(userId: "@bob:example.org", deviceId: "BOBDEVICE")])

    let sentContentJSON = try #require(toDeviceClient.sentContentJSON)
    let sentContent = try MatrixRTCCallEncryptionKeysContent(contentJSON: sentContentJSON)
    #expect(sentContent.keys == .init(index: 0, key: "own-key"))
    #expect(sentContent.member == .init(id: "@alice:example.org:ALICEDEVICE", claimedDeviceId: "ALICEDEVICE"))
    #expect(sentContent.roomId == "!room:example.org")

    let ownKey = try #require(keyBox.events.first?.key)
    #expect(ownKey.membership == ownMembership.identity)
    #expect(ownKey.rtcBackendIdentity == "@alice:example.org:ALICEDEVICE")
}

@Test func refreshSharesCurrentMediaKeyWithNewMembersOnly() async throws {
    let membershipClient = FakeSessionMembershipClient()
    let toDeviceClient = FakeCustomToDeviceClient()
    let ownMembership = sessionLegacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 10_000
    )
    let bobMembership = sessionLegacyMembership(
        eventId: "$bob",
        sender: "@bob:example.org",
        deviceId: "BOBDEVICE",
        createdTimestamp: 20_000
    )
    membershipClient.publishResult = ownMembership
    membershipClient.activeMembershipResponses = [[], [bobMembership], [bobMembership]]
    let session = MatrixRTCSession(
        configuration: .init(fociPreferred: []),
        membershipClient: membershipClient,
        keyTransportFactory: { identity in
            MatrixRTCToDeviceKeyTransport(
                roomId: "!room:example.org",
                ownIdentity: identity,
                client: toDeviceClient
            )
        },
        keyGenerator: StaticSessionMediaKeyGenerator(key: "own-key"),
        timestampProvider: { 10_000 },
        onKeyChanged: { _ in }
    )

    try await session.join()
    #expect(toDeviceClient.sendCount == 0)

    let firstRefresh = try await session.refreshMemberships()
    #expect(firstRefresh.keyShareResult.sharedWith == [.init(userId: "@bob:example.org", deviceId: "BOBDEVICE")])
    #expect(toDeviceClient.sendCount == 1)

    let secondRefresh = try await session.refreshMemberships()
    #expect(secondRefresh.keyShareResult.sharedWith.isEmpty)
    #expect(toDeviceClient.sendCount == 1)
}

@Test func refreshOwnMembershipExpiryExtendsExpiresWithoutChangingCreatedTimestamp() async throws {
    let membershipClient = FakeSessionMembershipClient()
    let toDeviceClient = FakeCustomToDeviceClient()
    let ownMembership = sessionLegacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 10_000,
        expires: 10_000
    )
    let refreshedMembership = sessionLegacyMembership(
        eventId: "$own-refresh",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 10_000,
        expires: 20_000
    )
    membershipClient.publishResults = [ownMembership, refreshedMembership]
    membershipClient.activeMembershipResponses = [[]]
    let session = MatrixRTCSession(
        configuration: .init(
            fociPreferred: [],
            expires: 10_000
        ),
        membershipClient: membershipClient,
        keyTransportFactory: { identity in
            MatrixRTCToDeviceKeyTransport(
                roomId: "!room:example.org",
                ownIdentity: identity,
                client: toDeviceClient
            )
        },
        keyGenerator: StaticSessionMediaKeyGenerator(key: "own-key"),
        timestampProvider: { 10_000 },
        onKeyChanged: { _ in }
    )

    try await session.join()
    let refreshed = try await session.refreshOwnMembershipExpiry()

    #expect(refreshed == refreshedMembership)
    #expect(session.ownMembership == refreshedMembership)
    #expect(session.memberships.map(\.identity) == [refreshedMembership.identity])
    #expect(membershipClient.publishCount == 2)
    #expect(membershipClient.publishedCreatedTimestampHistory == [10_000, 10_000])
    #expect(membershipClient.publishedExpiresHistory == [10_000, 20_000])
}

@Test func leavesSessionAndClearsLocalState() async throws {
    let membershipClient = FakeSessionMembershipClient()
    let toDeviceClient = FakeCustomToDeviceClient()
    let ownMembership = sessionLegacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 10_000
    )
    membershipClient.publishResult = ownMembership
    membershipClient.activeMembershipResponses = [[]]
    let session = MatrixRTCSession(
        configuration: .init(fociPreferred: []),
        membershipClient: membershipClient,
        keyTransportFactory: { identity in
            MatrixRTCToDeviceKeyTransport(
                roomId: "!room:example.org",
                ownIdentity: identity,
                client: toDeviceClient
            )
        },
        keyGenerator: StaticSessionMediaKeyGenerator(key: "own-key"),
        timestampProvider: { 10_000 },
        onKeyChanged: { _ in }
    )

    try await session.join()
    let leaveEventId = try await session.leave()

    #expect(leaveEventId == "$leave")
    #expect(membershipClient.leaveCount == 1)
    #expect(session.state == .left)
    #expect(session.ownMembership == nil)
    #expect(session.memberships.isEmpty)
    #expect(session.encryptionKeys().isEmpty)
}

@Test func reemitsKnownSessionEncryptionKeys() async throws {
    let membershipClient = FakeSessionMembershipClient()
    let toDeviceClient = FakeCustomToDeviceClient()
    let ownMembership = sessionLegacyMembership(
        eventId: "$own",
        sender: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        createdTimestamp: 10_000
    )
    membershipClient.publishResult = ownMembership
    membershipClient.activeMembershipResponses = [[]]
    let keyBox = SessionMediaKeyEventBox()
    let session = MatrixRTCSession(
        configuration: .init(fociPreferred: []),
        membershipClient: membershipClient,
        keyTransportFactory: { identity in
            MatrixRTCToDeviceKeyTransport(
                roomId: "!room:example.org",
                ownIdentity: identity,
                client: toDeviceClient
            )
        },
        keyGenerator: StaticSessionMediaKeyGenerator(key: "own-key"),
        timestampProvider: { 10_000 },
        onKeyChanged: { event in
            keyBox.events.append(event)
        }
    )

    try await session.join()
    session.reemitEncryptionKeys()

    #expect(keyBox.events.map(\.key.keyBase64Encoded) == ["own-key", "own-key"])
}

private final class FakeSessionMembershipClient: MatrixRTCSessionMembershipClient, @unchecked Sendable {
    var publishResult: MatrixRTCCallMembership?
    var publishResults: [MatrixRTCCallMembership] = []
    var activeMembershipResponses: [[MatrixRTCCallMembership]] = []
    var leaveEventId = "$leave"

    var publishCount = 0
    var loadCount = 0
    var leaveCount = 0

    var publishedFociPreferred: [MatrixRTCTransport]?
    var publishedCreatedTimestamp: Int64?
    var publishedCreatedTimestampHistory: [Int64?] = []
    var publishedExpiresHistory: [Int64] = []
    var publishedCallIntent: String?

    @discardableResult
    func publishOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?,
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection,
        fociPreferred: [MatrixRTCTransport],
        createdTimestamp: Int64?,
        expires: Int64,
        callIntent: String?
    ) async throws -> MatrixRTCCallMembership {
        publishCount += 1
        publishedFociPreferred = fociPreferred
        publishedCreatedTimestamp = createdTimestamp
        publishedCreatedTimestampHistory.append(createdTimestamp)
        publishedExpiresHistory.append(expires)
        publishedCallIntent = callIntent
        if !publishResults.isEmpty {
            return publishResults.removeFirst()
        }
        return try #require(publishResult)
    }

    func loadActiveMemberships(
        slot: MatrixRTCSlotDescription,
        joinedUserIds: Set<String>?,
        now: Int64
    ) async throws -> [MatrixRTCCallMembership] {
        loadCount += 1
        guard !activeMembershipResponses.isEmpty else {
            return []
        }
        if activeMembershipResponses.count == 1 {
            return activeMembershipResponses[0]
        }
        return activeMembershipResponses.removeFirst()
    }

    @discardableResult
    func leaveOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?
    ) async throws -> String {
        leaveCount += 1
        return leaveEventId
    }
}

private struct StaticSessionMediaKeyGenerator: MatrixRTCMediaKeyGenerating {
    let key: String

    func generateMediaKeyBase64Encoded() -> String {
        key
    }
}

private final class SessionMediaKeyEventBox: @unchecked Sendable {
    var events: [MatrixRTCMediaKeyChangedEvent] = []
}

private func sessionLegacyMembership(
    eventId: String,
    sender: String,
    deviceId: String,
    createdTimestamp: Int64,
    expires: Int64 = MatrixRTCCallMembership.defaultExpireDurationMilliseconds
) -> MatrixRTCCallMembership {
    let identity = MatrixRTCMembershipIdentity(
        userId: sender,
        deviceId: deviceId,
        memberId: "\(sender):\(deviceId)"
    )
    return MatrixRTCCallMembership(
        kind: .legacyState,
        eventId: eventId,
        eventType: MatrixRTCRawMembershipEvent.legacyCallMemberEventType,
        stateKey: "_\(sender)_\(deviceId)_m.call",
        sender: sender,
        identity: identity,
        slot: .matrixCallRoom,
        createdTimestamp: createdTimestamp,
        absoluteExpiryTimestamp: createdTimestamp + expires,
        rtcBackendIdentity: identity.legacyRTCBackendIdentity,
        transports: [],
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection.oldestMembership.rawValue,
        callIntent: nil
    )
}
