//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRTC
import MatrixRustSDK

final class MatrixRustSDKRTCSessionMembershipClient: MatrixRTCSessionMembershipClient, @unchecked Sendable {
    private let membershipClient: MatrixRustSDKRTCMembershipClient
    private let room: Room
    private let roomVersion: String?
    private let timestampProvider: @Sendable () -> Int64

    init(
        membershipClient: MatrixRustSDKRTCMembershipClient,
        room: Room,
        roomVersion: String? = nil,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.membershipClient = membershipClient
        self.room = room
        self.roomVersion = roomVersion
        self.timestampProvider = timestampProvider
    }

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
        let published = try await membershipClient.publishOwnLegacyMembership(
            room: room,
            slot: slot,
            roomVersion: roomVersion ?? self.roomVersion,
            focusSelection: focusSelection,
            fociPreferred: fociPreferred,
            createdTimestamp: createdTimestamp,
            expires: expires,
            callIntent: callIntent
        )
        let effectiveCreatedTimestamp = published.createdTimestamp ?? createdTimestamp ?? timestampProvider()

        return MatrixRTCCallMembership(
            kind: .legacyState,
            eventId: published.eventId,
            eventType: MatrixRTCRawMembershipEvent.legacyCallMemberEventType,
            stateKey: published.stateKey,
            sender: published.identity.userId,
            identity: published.identity,
            slot: slot,
            createdTimestamp: effectiveCreatedTimestamp,
            absoluteExpiryTimestamp: effectiveCreatedTimestamp + expires,
            rtcBackendIdentity: published.identity.legacyRTCBackendIdentity,
            transports: fociPreferred,
            focusSelection: focusSelection.rawValue,
            callIntent: callIntent
        )
    }

    func loadActiveMemberships(
        slot: MatrixRTCSlotDescription,
        joinedUserIds: Set<String>?,
        now: Int64
    ) async throws -> [MatrixRTCCallMembership] {
        try await membershipClient.loadActiveMemberships(
            roomId: room.id(),
            slot: slot,
            joinedUserIds: joinedUserIds,
            now: now
        )
    }

    @discardableResult
    func leaveOwnLegacyMembership(
        slot: MatrixRTCSlotDescription,
        roomVersion: String?
    ) async throws -> String {
        try await membershipClient.leaveOwnLegacyMembership(
            room: room,
            slot: slot,
            roomVersion: roomVersion ?? self.roomVersion
        )
    }
}
