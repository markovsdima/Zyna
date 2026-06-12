//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRTC
import MatrixRustSDK
import Testing
@testable import Zyna

@Suite("NativeMatrixRTCCallRaisedHandStore")
struct NativeMatrixRTCCallReactionsTests {
    @Test("Parses Element Call raised hand reaction")
    func parsesRaisedHandReaction() throws {
        let event = NativeMatrixRTCCallReactionEventParser.parse(rawJSON: """
        {
          "type": "m.reaction",
          "event_id": "$reaction",
          "sender": "@alice:example.org",
          "origin_server_ts": 1000,
          "content": {
            "m.relates_to": {
              "rel_type": "m.annotation",
              "event_id": "$membership",
              "key": "🖐️"
            }
          }
        }
        """)

        #expect(event == .raisedHand(
            reactionEventId: "$reaction",
            membershipEventId: "$membership",
            sender: "@alice:example.org",
            timestamp: Date(timeIntervalSince1970: 1)
        ))
    }

    @Test("Parses raised hand from raw room event")
    func parsesRawRoomRaisedHandEvent() {
        let event = NativeMatrixRTCCallReactionEventParser.parse(RawRoomEvent(
            roomId: "!room:example.org",
            eventType: "m.reaction",
            eventId: "$reaction",
            sender: "@alice:example.org",
            originServerTsMs: 1_000,
            contentJson: """
            {
              "m.relates_to": {
                "rel_type": "m.annotation",
                "event_id": "$membership",
                "key": "🖐️"
              }
            }
            """,
            rawJson: """
            {
              "type": "m.room.encrypted",
              "event_id": "$encrypted",
              "sender": "@alice:example.org",
              "origin_server_ts": 999,
              "content": {}
            }
            """,
            encryptionInfo: RawRoomEventEncryptionInfo(
                sender: "@alice:example.org",
                senderDevice: "ALICE",
                senderCurve25519KeyBase64: nil,
                senderVerified: true
            )
        ))

        #expect(event == .raisedHand(
            reactionEventId: "$reaction",
            membershipEventId: "$membership",
            sender: "@alice:example.org",
            timestamp: Date(timeIntervalSince1970: 1)
        ))
    }

    @Test("Redaction lowers a raised hand")
    func redactionLowersRaisedHand() {
        var store = NativeMatrixRTCCallRaisedHandStore()
        let own = membership(
            eventId: "$own-member",
            userId: "@me:example.org",
            deviceId: "ME"
        )
        let alice = membership(
            eventId: "$alice-member",
            userId: "@alice:example.org",
            deviceId: "ALICE"
        )

        _ = store.updateMemberships(ownMembership: own, memberships: [own, alice])
        var snapshot = store.apply(.raisedHand(
            reactionEventId: "$reaction",
            membershipEventId: alice.eventId,
            sender: alice.userId,
            timestamp: Date(timeIntervalSince1970: 10)
        ))

        #expect(snapshot?.handsByParticipantId[alice.rtcBackendIdentity]?.isRaised == true)

        snapshot = store.apply(.redaction(redactedEventId: "$reaction"))

        #expect(snapshot?.handsByParticipantId[alice.rtcBackendIdentity] == nil)
    }

    @Test("Raised hand ignores sender that does not own membership")
    func ignoresSenderMismatch() {
        var store = NativeMatrixRTCCallRaisedHandStore()
        let own = membership(
            eventId: "$own-member",
            userId: "@me:example.org",
            deviceId: "ME"
        )
        let alice = membership(
            eventId: "$alice-member",
            userId: "@alice:example.org",
            deviceId: "ALICE"
        )

        _ = store.updateMemberships(ownMembership: own, memberships: [own, alice])
        let snapshot = store.apply(.raisedHand(
            reactionEventId: "$reaction",
            membershipEventId: alice.eventId,
            sender: "@mallory:example.org",
            timestamp: Date(timeIntervalSince1970: 10)
        ))

        #expect(snapshot == nil)
        #expect(store.snapshot.handsByParticipantId.isEmpty)
    }

    @Test("Membership refresh hides stale raised hand")
    func membershipRefreshHidesStaleRaisedHand() {
        var store = NativeMatrixRTCCallRaisedHandStore()
        let own = membership(
            eventId: "$own-member",
            userId: "@me:example.org",
            deviceId: "ME"
        )
        let oldAlice = membership(
            eventId: "$alice-old-member",
            userId: "@alice:example.org",
            deviceId: "ALICE"
        )
        let newAlice = membership(
            eventId: "$alice-new-member",
            userId: "@alice:example.org",
            deviceId: "ALICE"
        )

        _ = store.updateMemberships(ownMembership: own, memberships: [own, oldAlice])
        _ = store.apply(.raisedHand(
            reactionEventId: "$reaction",
            membershipEventId: oldAlice.eventId,
            sender: oldAlice.userId,
            timestamp: Date(timeIntervalSince1970: 10)
        ))

        let snapshot = store.updateMemberships(ownMembership: own, memberships: [own, newAlice])

        #expect(snapshot?.handsByParticipantId[newAlice.rtcBackendIdentity] == nil)
    }

    @Test("Raised hand is buffered until membership appears")
    func buffersRaisedHandUntilMembershipAppears() {
        var store = NativeMatrixRTCCallRaisedHandStore()
        let own = membership(
            eventId: "$own-member",
            userId: "@me:example.org",
            deviceId: "ME"
        )
        let alice = membership(
            eventId: "$alice-member",
            userId: "@alice:example.org",
            deviceId: "ALICE"
        )

        _ = store.updateMemberships(ownMembership: own, memberships: [own])
        let firstSnapshot = store.apply(.raisedHand(
            reactionEventId: "$reaction",
            membershipEventId: alice.eventId,
            sender: alice.userId,
            timestamp: Date(timeIntervalSince1970: 10)
        ))

        #expect(firstSnapshot == nil)
        #expect(store.snapshot.handsByParticipantId[alice.rtcBackendIdentity] == nil)

        let secondSnapshot = store.updateMemberships(ownMembership: own, memberships: [own, alice])

        #expect(secondSnapshot?.handsByParticipantId[alice.rtcBackendIdentity]?.isRaised == true)
    }

    @Test("Redaction before backfill suppresses raised hand")
    func redactionBeforeBackfillSuppressesRaisedHand() {
        var store = NativeMatrixRTCCallRaisedHandStore()
        let own = membership(
            eventId: "$own-member",
            userId: "@me:example.org",
            deviceId: "ME"
        )
        let alice = membership(
            eventId: "$alice-member",
            userId: "@alice:example.org",
            deviceId: "ALICE"
        )

        _ = store.updateMemberships(ownMembership: own, memberships: [own, alice])
        let firstSnapshot = store.apply(.redaction(redactedEventId: "$reaction"))
        let secondSnapshot = store.apply(.raisedHand(
            reactionEventId: "$reaction",
            membershipEventId: alice.eventId,
            sender: alice.userId,
            timestamp: Date(timeIntervalSince1970: 10)
        ))

        #expect(firstSnapshot == nil)
        #expect(secondSnapshot == nil)
        #expect(store.snapshot.handsByParticipantId[alice.rtcBackendIdentity] == nil)
    }
}

private func membership(
    eventId: String,
    userId: String,
    deviceId: String
) -> MatrixRTCCallMembership {
    let identity = MatrixRTCMembershipIdentity(
        userId: userId,
        deviceId: deviceId,
        memberId: "\(userId):\(deviceId)"
    )
    return MatrixRTCCallMembership(
        kind: .legacyState,
        eventId: eventId,
        eventType: MatrixRTCRawMembershipEvent.legacyCallMemberEventType,
        stateKey: "\(userId)_\(deviceId)",
        sender: userId,
        identity: identity,
        slot: .matrixCallRoom,
        createdTimestamp: 1_000,
        absoluteExpiryTimestamp: nil,
        rtcBackendIdentity: identity.legacyRTCBackendIdentity,
        transports: [],
        focusSelection: nil,
        callIntent: "audio"
    )
}
