//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Testing
@testable import Zyna

@Suite("MatrixRTC call log")
struct MatrixRTCCallLogTests {

    @Test("Outgoing direct call is answered when the remote user joins")
    func outgoingDirectCallAnsweredByRemoteJoin() {
        let call = makeCall(isOutgoing: true)
        let membership = makeMembership(
            eventId: "$remote-member",
            senderId: remoteUserId,
            timestamp: call.timestamp + 1
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [membership],
            now: now
        )

        #expect(outcome == .answered)
    }

    @Test("Incoming direct call is answered when the current user joins")
    func incomingDirectCallAnsweredByOwnJoin() {
        let call = makeCall(isOutgoing: false)
        let membership = makeMembership(
            eventId: "$own-member",
            senderId: currentUserId,
            timestamp: call.timestamp + 1
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [membership],
            now: now
        )

        #expect(outcome == .answered)
    }

    @Test("Expired incoming ring with only caller membership is missed")
    func expiredIncomingRingWithOnlyCallerMembershipIsMissed() {
        let call = makeCall(isOutgoing: false)
        let membership = makeMembership(
            eventId: "$remote-member",
            senderId: remoteUserId,
            timestamp: call.timestamp + 1
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [membership],
            now: now
        )

        #expect(outcome == .missed)
    }

    @Test("Expired outgoing ring with only own membership is unanswered")
    func expiredOutgoingRingWithOnlyOwnMembershipIsUnanswered() {
        let call = makeCall(isOutgoing: true)
        let membership = makeMembership(
            eventId: "$own-member",
            senderId: currentUserId,
            timestamp: call.timestamp + 1
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [membership],
            now: now
        )

        #expect(outcome == .unanswered)
    }

    @Test("Outgoing direct call cancelled by current user before remote joins")
    func outgoingDirectCallCancelledByCurrentUserBeforeRemoteJoin() {
        let call = makeCall(isOutgoing: true)
        let ownJoin = makeMembership(
            eventId: "$own-member",
            senderId: currentUserId,
            timestamp: call.timestamp + 1
        )
        let ownLeave = makeMembership(
            eventId: "$own-leave",
            senderId: currentUserId,
            timestamp: call.timestamp + 2,
            isLeave: true
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [ownJoin, ownLeave],
            now: Date(timeIntervalSince1970: call.timestamp + 3)
        )

        #expect(outcome == .cancelledByMe)
    }

    @Test("Incoming direct call is missed when caller leaves before current user joins")
    func incomingDirectCallMissedWhenCallerLeavesBeforeOwnJoin() {
        let call = makeCall(isOutgoing: false)
        let remoteJoin = makeMembership(
            eventId: "$remote-member",
            senderId: remoteUserId,
            timestamp: call.timestamp + 1
        )
        let remoteLeave = makeMembership(
            eventId: "$remote-leave",
            senderId: remoteUserId,
            timestamp: call.timestamp + 2,
            isLeave: true
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [remoteJoin, remoteLeave],
            now: Date(timeIntervalSince1970: call.timestamp + 3)
        )

        #expect(outcome == .missed)
    }

    @Test("Answered direct call stays answered after participants leave")
    func answeredDirectCallStaysAnsweredAfterLeave() {
        let call = makeCall(isOutgoing: true)
        let ownJoin = makeMembership(
            eventId: "$own-member",
            senderId: currentUserId,
            timestamp: call.timestamp + 1
        )
        let remoteJoin = makeMembership(
            eventId: "$remote-member",
            senderId: remoteUserId,
            timestamp: call.timestamp + 2
        )
        let ownLeave = makeMembership(
            eventId: "$own-leave",
            senderId: currentUserId,
            timestamp: call.timestamp + 3,
            isLeave: true
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [ownJoin, remoteJoin, ownLeave],
            now: Date(timeIntervalSince1970: call.timestamp + 4)
        )

        #expect(outcome == .answered)
    }

    @Test("Decline by current user wins over timeout")
    func declinedByCurrentUserWinsOverTimeout() {
        let call = makeCall(
            isOutgoing: false,
            declinedByJSON: "[\"\(currentUserId)\"]"
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [],
            now: now
        )

        #expect(outcome == .declinedByMe)
    }

    @Test("Group calls stay as started from membership evidence")
    func groupCallWithMembershipStaysStarted() {
        let call = makeCall(isOutgoing: false)
        let membership = makeMembership(
            eventId: "$member",
            senderId: remoteUserId,
            timestamp: call.timestamp + 1
        )

        let outcome = call.outcome(
            isDirect: false,
            currentUserId: currentUserId,
            memberships: [membership],
            now: now
        )

        #expect(outcome == .started)
    }

    @Test("Projection is not classified when current user id is unavailable")
    func emptyCurrentUserIdKeepsProjectionStarted() {
        let call = makeCall(isOutgoing: false)
        let membership = makeMembership(
            eventId: "$remote-member",
            senderId: remoteUserId,
            timestamp: call.timestamp + 1
        )

        let outcome = call.outcome(
            isDirect: true,
            currentUserId: "",
            memberships: [membership],
            now: now
        )

        #expect(outcome == .started)
    }

    @Test("Projection materializes answered outcome and membership evidence")
    func projectionMaterializesAnsweredOutcome() {
        var call = makeCall(isOutgoing: true)
        let membership = makeMembership(
            eventId: "$remote-member",
            senderId: remoteUserId,
            timestamp: call.timestamp + 1
        )

        call.refreshProjection(
            isDirect: true,
            currentUserId: currentUserId,
            memberships: [membership],
            now: now
        )

        #expect(call.historyOutcome == .answered)
        #expect(call.isDirect)
        #expect(!call.hasOwnJoin)
        #expect(call.hasRemoteJoin)
        #expect(!call.hasOwnLeave)
        #expect(!call.hasRemoteLeave)
        #expect(call.lastMembershipEventTimestamp == membership.timestamp)
    }

    @Test("Chat call details prefer materialized history outcome")
    func chatDetailsPreferMaterializedOutcome() {
        let details = MatrixRTCCallEventDetails(
            parentEventId: "$parent-member",
            callIntent: "m.audio",
            notificationType: .ring,
            expiresAt: 1_030,
            declinedBy: [],
            historyOutcome: .missed
        )

        #expect(details.timelineText(isDirect: true, currentUserId: currentUserId) == MatrixRTCCallHistoryOutcome.missed.displayText)
    }
}

private let currentUserId = "@me:example.org"
private let remoteUserId = "@alice:example.org"
private let now = Date(timeIntervalSince1970: 2_000)

private func makeCall(
    isOutgoing: Bool,
    declinedByJSON: String = "[]"
) -> StoredMatrixRTCCall {
    StoredMatrixRTCCall(
        notificationEventId: "$notification",
        roomId: "!room:example.org",
        parentEventId: "$parent-member",
        senderId: isOutgoing ? currentUserId : remoteUserId,
        senderDisplayName: nil,
        isOutgoing: isOutgoing,
        timestamp: 1_000,
        notificationType: MatrixRTCCallNotificationKind.ring.rawValue,
        callIntent: "m.audio",
        expiresAt: 1_030,
        declinedByJSON: declinedByJSON,
        isDirect: false,
        hasOwnJoin: false,
        hasRemoteJoin: false,
        hasOwnLeave: false,
        hasRemoteLeave: false,
        lastMembershipEventTimestamp: nil,
        lastOwnLeaveTimestamp: nil,
        lastRemoteLeaveTimestamp: nil,
        outcome: MatrixRTCCallHistoryOutcome.started.rawValue,
        updatedAt: 1_000
    )
}

private func makeMembership(
    eventId: String,
    senderId: String,
    timestamp: TimeInterval,
    isLeave: Bool = false
) -> StoredMatrixRTCCallMembership {
    StoredMatrixRTCCallMembership(
        eventId: eventId,
        roomId: "!room:example.org",
        eventType: "org.matrix.msc3401.call.member",
        stateKey: senderId,
        senderId: senderId,
        timestamp: timestamp,
        isLeave: isLeave,
        userId: senderId,
        deviceId: isLeave ? nil : "DEVICE",
        memberId: isLeave ? nil : "member-\(senderId)",
        callIntent: isLeave ? nil : "m.audio",
        expiresAt: isLeave ? nil : timestamp + 60
    )
}
