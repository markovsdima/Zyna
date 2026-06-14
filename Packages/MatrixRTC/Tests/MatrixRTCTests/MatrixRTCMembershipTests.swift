import Testing
@testable import MatrixRTC

@Test func parsesLegacyRoomMembership() throws {
    let event = legacyEvent(
        eventId: "$legacy1",
        sender: "@alice:example.org",
        originServerTimestamp: 1_000,
        contentJSON: """
        {
          "application": "m.call",
          "call_id": "",
          "scope": "m.room",
          "device_id": "ALICEDEVICE",
          "focus_active": {
            "type": "livekit",
            "focus_selection": "oldest_membership"
          },
          "foci_preferred": [
            {
              "type": "livekit",
              "livekit_service_url": "https://livekit.example.org"
            }
          ],
          "expires": 10000,
          "m.call.intent": "m.audio"
        }
        """
    )

    let membership = try MatrixRTCCallMembershipParser.parse(event: event)

    #expect(membership.kind == .legacyState)
    #expect(membership.slot == .matrixCallRoom)
    #expect(membership.slot.legacyCallId == "")
    #expect(membership.identity == .init(
        userId: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        memberId: "@alice:example.org:ALICEDEVICE"
    ))
    #expect(membership.createdTimestamp == 1_000)
    #expect(membership.absoluteExpiryTimestamp == 11_000)
    #expect(membership.rtcBackendIdentity == "@alice:example.org:ALICEDEVICE")
    #expect(membership.transports.first?.type == "livekit")
    #expect(membership.transports.first?.liveKitServiceURL == "https://livekit.example.org")
    #expect(membership.focusSelection == "oldest_membership")
    #expect(membership.callIntent == "m.audio")
}

@Test func parsesLegacyMembershipIdWithoutChangingBackendIdentity() throws {
    let event = legacyEvent(
        eventId: "$legacy2",
        sender: "@alice:example.org",
        originServerTimestamp: 1_000,
        contentJSON: """
        {
          "application": "m.call",
          "call_id": "",
          "device_id": "ALICEDEVICE",
          "focus_active": {
            "type": "livekit",
            "focus_selection": "multi_sfu"
          },
          "foci_preferred": [],
          "created_ts": 500,
          "membershipID": "custom-member"
        }
        """
    )

    let membership = try MatrixRTCCallMembershipParser.parse(event: event)

    #expect(membership.memberId == "custom-member")
    #expect(membership.createdTimestamp == 500)
    #expect(membership.rtcBackendIdentity == "@alice:example.org:ALICEDEVICE")
}

@Test func filtersActiveMembershipsForSlotAndJoinedUsers() {
    let events = [
        legacyEvent(
            eventId: "$valid2",
            sender: "@bob:example.org",
            originServerTimestamp: 2_000,
            contentJSON: legacyMembershipJSON(deviceId: "BOBDEVICE", createdTimestamp: 2_000, expires: 50_000)
        ),
        legacyEvent(
            eventId: "$expired",
            sender: "@expired:example.org",
            originServerTimestamp: 1_000,
            contentJSON: legacyMembershipJSON(deviceId: "OLDDEVICE", createdTimestamp: 1_000, expires: 100)
        ),
        legacyEvent(
            eventId: "$other-slot",
            sender: "@other:example.org",
            originServerTimestamp: 3_000,
            contentJSON: legacyMembershipJSON(deviceId: "OTHERDEVICE", callId: "breakout", createdTimestamp: 3_000, expires: 50_000)
        ),
        legacyEvent(
            eventId: "$not-joined",
            sender: "@mallory:example.org",
            originServerTimestamp: 4_000,
            contentJSON: legacyMembershipJSON(deviceId: "MALLORYDEVICE", createdTimestamp: 4_000, expires: 50_000)
        ),
        legacyEvent(
            eventId: "$valid1",
            sender: "@alice:example.org",
            originServerTimestamp: 1_500,
            contentJSON: legacyMembershipJSON(deviceId: "ALICEDEVICE", createdTimestamp: 1_500, expires: 50_000)
        ),
    ]

    let memberships = MatrixRTCCallMembershipParser.activeMemberships(
        from: events,
        for: .matrixCallRoom,
        joinedUserIds: ["@alice:example.org", "@bob:example.org"],
        now: 10_000
    )

    #expect(memberships.map(\.userId) == ["@alice:example.org", "@bob:example.org"])
    #expect(memberships.map(\.createdTimestamp) == [1_500, 2_000])
}

@Test func buildsUniqueToDeviceTargetsExcludingOwnDevice() {
    let memberships = MatrixRTCCallMembershipParser.activeMemberships(
        from: [
            legacyEvent(
                eventId: "$own",
                sender: "@alice:example.org",
                originServerTimestamp: 1_000,
                contentJSON: legacyMembershipJSON(deviceId: "ALICEDEVICE", createdTimestamp: 1_000, expires: 50_000)
            ),
            legacyEvent(
                eventId: "$bob1",
                sender: "@bob:example.org",
                originServerTimestamp: 2_000,
                contentJSON: legacyMembershipJSON(deviceId: "BOBDEVICE", createdTimestamp: 2_000, expires: 50_000)
            ),
            legacyEvent(
                eventId: "$bob2",
                sender: "@bob:example.org",
                originServerTimestamp: 3_000,
                contentJSON: legacyMembershipJSON(deviceId: "BOBDEVICE", createdTimestamp: 3_000, expires: 50_000)
            ),
        ],
        now: 10_000
    )

    let targets = MatrixRTCCallMembershipParser.toDeviceTargets(
        from: memberships,
        excluding: .init(userId: "@alice:example.org", deviceId: "ALICEDEVICE", memberId: "@alice:example.org:ALICEDEVICE")
    )

    #expect(targets == [.init(userId: "@bob:example.org", deviceId: "BOBDEVICE")])
}

@Test func parsesRTCMemberWithHashedBackendIdentity() throws {
    let event = MatrixRTCRawMembershipEvent(
        eventId: "$rtc1",
        eventType: MatrixRTCRawMembershipEvent.rtcMemberEventType,
        stateKey: nil,
        sender: "@alice:example.com",
        originServerTimestamp: 1_000,
        contentJSON: """
        {
          "slot_id": "m.call#ROOM",
          "member": {
            "user_id": "@alice:example.com",
            "device_id": "DEVICE123",
            "id": "memberABC"
          },
          "application": {
            "type": "m.call",
            "m.call.intent": "m.video"
          },
          "rtc_transports": [
            {
              "type": "livekit",
              "livekit_service_url": "https://livekit.example.org"
            }
          ],
          "versions": ["1"],
          "sticky_key": "memberABC"
        }
        """
    )

    let membership = try MatrixRTCCallMembershipParser.parse(event: event)

    #expect(membership.kind == .rtc)
    #expect(membership.slot == .matrixCallRoom)
    #expect(membership.identity == .init(
        userId: "@alice:example.com",
        deviceId: "DEVICE123",
        memberId: "memberABC"
    ))
    #expect(membership.absoluteExpiryTimestamp == nil)
    #expect(membership.rtcBackendIdentity == "J+T45tGruxc+HrUOqJJlyQSV33m728Cme4+vt8/SWrU")
    #expect(membership.callIntent == "m.video")
}

@Test func buildsLegacyOwnMembershipStateKey() {
    #expect(MatrixRTCLegacyCallMembershipStateEvent.stateKey(
        userId: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        slot: .matrixCallRoom
    ) == "_@alice:example.org_ALICEDEVICE_m.call")

    #expect(MatrixRTCLegacyCallMembershipStateEvent.stateKey(
        userId: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        slot: .init(application: "m.call", id: "breakout")
    ) == "_@alice:example.org_ALICEDEVICE_m.callbreakout")

    #expect(MatrixRTCLegacyCallMembershipStateEvent.stateKey(
        userId: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        slot: .matrixCallRoom,
        roomVersion: "org.matrix.msc3757.10"
    ) == "@alice:example.org_ALICEDEVICE_m.call")
}

@Test func buildsLegacyOwnMembershipContent() throws {
    let event = MatrixRTCLegacyCallMembershipStateEvent(
        userId: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        focusSelection: .multiSFU,
        fociPreferred: [
            .liveKit(serviceURL: "https://livekit.example.org"),
        ],
        createdTimestamp: 123_456,
        expires: 14_400_000,
        callIntent: "m.audio"
    )

    let content = try MatrixRTCLegacyCallMembershipContent(contentJSON: event.contentJSON())

    #expect(event.identity == .init(
        userId: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        memberId: "@alice:example.org:ALICEDEVICE"
    ))
    #expect(event.stateKey == "_@alice:example.org_ALICEDEVICE_m.call")
    #expect(content.application == "m.call")
    #expect(content.callId == "")
    #expect(content.scope == "m.room")
    #expect(content.deviceId == "ALICEDEVICE")
    #expect(content.membershipID == "@alice:example.org:ALICEDEVICE")
    #expect(content.focusActive.type == "livekit")
    #expect(content.focusActive.focusSelection == .multiSFU)
    #expect(content.fociPreferred.first?.liveKitServiceURL == "https://livekit.example.org")
    #expect(content.createdTimestamp == 123_456)
    #expect(content.expires == 14_400_000)
    #expect(content.callIntent == "m.audio")
}

@Test func buildsLegacyOwnJoinContentWithoutCreatedTimestamp() throws {
    let event = MatrixRTCLegacyCallMembershipStateEvent(
        userId: "@alice:example.org",
        deviceId: "ALICEDEVICE",
        focusSelection: .oldestMembership,
        fociPreferred: [],
        createdTimestamp: nil,
        callIntent: nil
    )

    let content = try MatrixRTCLegacyCallMembershipContent(contentJSON: event.contentJSON())

    #expect(content.createdTimestamp == nil)
    #expect(content.callIntent == nil)
    #expect(content.expires == MatrixRTCCallMembership.defaultExpireDurationMilliseconds)
    #expect(MatrixRTCLegacyCallMembershipStateEvent.leaveContentJSON == "{}")
}

private func legacyEvent(
    eventId: String,
    sender: String,
    originServerTimestamp: Int64,
    contentJSON: String
) -> MatrixRTCRawMembershipEvent {
    MatrixRTCRawMembershipEvent(
        eventId: eventId,
        eventType: MatrixRTCRawMembershipEvent.legacyCallMemberEventType,
        stateKey: "_\(sender)_DEVICE_m.call",
        sender: sender,
        originServerTimestamp: originServerTimestamp,
        contentJSON: contentJSON
    )
}

private func legacyMembershipJSON(
    deviceId: String,
    callId: String = "",
    createdTimestamp: Int64,
    expires: Int64
) -> String {
    """
    {
      "application": "m.call",
      "call_id": "\(callId)",
      "device_id": "\(deviceId)",
      "focus_active": {
        "type": "livekit",
        "focus_selection": "oldest_membership"
      },
      "foci_preferred": [],
      "created_ts": \(createdTimestamp),
      "expires": \(expires)
    }
    """
}
