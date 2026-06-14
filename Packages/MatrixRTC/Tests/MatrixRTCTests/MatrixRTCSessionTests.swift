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

@Test func joinsUnencryptedSessionWithoutMediaKeyTransport() async throws {
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
    let keyTransportFactoryCalled = SessionFlagBox()

    let session = MatrixRTCSession(
        configuration: .init(
            fociPreferred: [.liveKit(serviceURL: "https://livekit.example.org")],
            callIntent: "m.audio",
            mediaEncryptionMode: .unencrypted
        ),
        membershipClient: membershipClient,
        keyTransportFactory: { identity in
            keyTransportFactoryCalled.value = true
            return MatrixRTCToDeviceKeyTransport(
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

    let joinResult = try await session.join()
    let refreshResult = try await session.refreshMemberships()
    let reshareResult = try await session.reshareCurrentMediaKey()

    #expect(session.state == .joined)
    #expect(joinResult.memberships.map(\.identity) == [ownMembership.identity, bobMembership.identity])
    #expect(joinResult.keyShareResult.sharedWith.isEmpty)
    #expect(refreshResult.keyShareResult.sharedWith.isEmpty)
    #expect(reshareResult.keyShareResult.sharedWith.isEmpty)
    #expect(keyTransportFactoryCalled.value == false)
    #expect(toDeviceClient.listenerEventType == nil)
    #expect(toDeviceClient.sendCount == 0)
    #expect(keyBox.events.isEmpty)
    #expect(session.encryptionKeys().isEmpty)
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

@Test func refreshMembershipsCanSkipKeyDistribution() async throws {
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
    let readOnlyRefresh = try await session.refreshMemberships(distributeKeys: false)
    #expect(readOnlyRefresh.memberships.map(\.identity) == [ownMembership.identity, bobMembership.identity])
    #expect(readOnlyRefresh.keyShareResult.sharedWith.isEmpty)
    #expect(toDeviceClient.sendCount == 0)

    let distributingRefresh = try await session.refreshMemberships()
    #expect(distributingRefresh.keyShareResult.sharedWith == [.init(userId: "@bob:example.org", deviceId: "BOBDEVICE")])
    #expect(toDeviceClient.sendCount == 1)
}

@Test func joinAppliesMediaKeysReceivedBeforeManagerIsReady() async throws {
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
    let emittedBeforePublishReturned = SessionFlagBox()
    membershipClient.publishHook = {
        emittedBeforePublishReturned.value = toDeviceClient.listener != nil
        let content = MatrixRTCCallEncryptionKeysContent(
            keys: .init(index: 4, key: "bob-key"),
            member: .init(id: bobMembership.memberId, claimedDeviceId: bobMembership.deviceId),
            roomId: "!room:example.org",
            sentTimestamp: 11_000
        )
        guard let contentJSON = try? content.jsonString() else { return }
        toDeviceClient.emit(.init(
            eventType: MatrixRTCCallEncryptionKeysContent.eventType,
            sender: "@spoofed:example.org",
            contentJSON: contentJSON,
            rawJSON: "{}",
            encryptionInfo: .init(
                sender: bobMembership.userId,
                senderDevice: bobMembership.deviceId,
                senderCurve25519KeyBase64: "curve-key",
                senderVerified: true
            )
        ))
    }
    let session = MatrixRTCSession(
        configuration: .init(
            ownMembershipIdentity: ownMembership.identity,
            fociPreferred: []
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

    try await session.join()

    #expect(emittedBeforePublishReturned.value)
    #expect(toDeviceClient.listenerEventType == MatrixRTCCallEncryptionKeysContent.eventType)
    #expect(keyBox.events.contains { event in
        event.key.membership == bobMembership.identity
            && event.key.keyBase64Encoded == "bob-key"
            && event.key.keyIndex == 4
            && event.key.rtcBackendIdentity == bobMembership.rtcBackendIdentity
    })
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

@Test func joinSchedulesDelayedLeaveWhenSupported() async throws {
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
    membershipClient.delayedLeaveEventId = "delay-1"
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

    #expect(membershipClient.scheduledDelayedLeaveSlots == [.matrixCallRoom])
    #expect(membershipClient.scheduledDelayedLeaveRoomVersions == [nil])
    #expect(membershipClient.scheduledDelayedLeaveDelays == [18_000])
}

@Test func leaveSendsScheduledDelayedLeaveWhenAvailable() async throws {
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
    membershipClient.delayedLeaveEventId = "delay-1"
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

    #expect(leaveEventId == nil)
    #expect(membershipClient.sentDelayedEventIds == ["delay-1"])
    #expect(membershipClient.leaveCount == 0)
    #expect(session.state == .left)
}

@Test func leaveFallsBackToImmediateLeaveWhenScheduledDelayedLeaveFails() async throws {
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
    membershipClient.delayedLeaveEventId = "delay-1"
    membershipClient.sendDelayedEventError = MatrixRTCSessionDelayedEventError.notFound
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
    #expect(membershipClient.sentDelayedEventIds == ["delay-1"])
    #expect(membershipClient.leaveCount == 1)
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
    var delayedLeaveEventId: String?
    var sendDelayedEventError: Error?
    var publishHook: (@Sendable () -> Void)?

    var publishCount = 0
    var loadCount = 0
    var leaveCount = 0

    var publishedFociPreferred: [MatrixRTCTransport]?
    var publishedCreatedTimestamp: Int64?
    var publishedCreatedTimestampHistory: [Int64?] = []
    var publishedExpiresHistory: [Int64] = []
    var publishedCallIntent: String?
    var scheduledDelayedLeaveSlots: [MatrixRTCSlotDescription] = []
    var scheduledDelayedLeaveRoomVersions: [String?] = []
    var scheduledDelayedLeaveDelays: [UInt64] = []
    var restartedDelayedEventIds: [String] = []
    var sentDelayedEventIds: [String] = []
    var canceledDelayedEventIds: [String] = []

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
        publishHook?()
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

    @discardableResult
    func scheduleDelayedLeaveOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?,
        delayMilliseconds: UInt64
    ) async throws -> String {
        scheduledDelayedLeaveSlots.append(slot)
        scheduledDelayedLeaveRoomVersions.append(roomVersion)
        scheduledDelayedLeaveDelays.append(delayMilliseconds)
        guard let delayedLeaveEventId else {
            throw MatrixRTCSessionDelayedEventError.unsupported
        }
        return delayedLeaveEventId
    }

    func restartDelayedEvent(delayId: String) async throws {
        restartedDelayedEventIds.append(delayId)
    }

    func sendDelayedEvent(delayId: String) async throws {
        sentDelayedEventIds.append(delayId)
        if let sendDelayedEventError {
            throw sendDelayedEventError
        }
    }

    func cancelDelayedEvent(delayId: String) async throws {
        canceledDelayedEventIds.append(delayId)
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

private final class SessionFlagBox: @unchecked Sendable {
    var value = false
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
