import Foundation

public struct MatrixRTCCallMembership: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case legacyState
        case rtc
    }

    public static let defaultExpireDurationMilliseconds: Int64 = 4 * 60 * 60 * 1000

    public let kind: Kind
    public let eventId: String
    public let eventType: String
    public let stateKey: String?
    public let sender: String
    public let identity: MatrixRTCMembershipIdentity
    public let slot: MatrixRTCSlotDescription
    public let createdTimestamp: Int64
    public let absoluteExpiryTimestamp: Int64?
    public let rtcBackendIdentity: String
    public let transports: [MatrixRTCTransport]
    public let focusSelection: String?
    public let callIntent: String?

    public init(
        kind: Kind,
        eventId: String,
        eventType: String,
        stateKey: String?,
        sender: String,
        identity: MatrixRTCMembershipIdentity,
        slot: MatrixRTCSlotDescription,
        createdTimestamp: Int64,
        absoluteExpiryTimestamp: Int64?,
        rtcBackendIdentity: String,
        transports: [MatrixRTCTransport],
        focusSelection: String?,
        callIntent: String?
    ) {
        self.kind = kind
        self.eventId = eventId
        self.eventType = eventType
        self.stateKey = stateKey
        self.sender = sender
        self.identity = identity
        self.slot = slot
        self.createdTimestamp = createdTimestamp
        self.absoluteExpiryTimestamp = absoluteExpiryTimestamp
        self.rtcBackendIdentity = rtcBackendIdentity
        self.transports = transports
        self.focusSelection = focusSelection
        self.callIntent = callIntent
    }

    public var userId: String {
        identity.userId
    }

    public var deviceId: String {
        identity.deviceId
    }

    public var memberId: String {
        identity.memberId
    }

    public var toDeviceTarget: MatrixRTCToDeviceTarget {
        MatrixRTCToDeviceTarget(userId: userId, deviceId: deviceId)
    }

    public func isExpired(at timestamp: Int64) -> Bool {
        guard let absoluteExpiryTimestamp else {
            return false
        }
        return absoluteExpiryTimestamp <= timestamp
    }
}

public enum MatrixRTCCallMembershipParseError: Error, Equatable {
    case unsupportedEventType(String)
    case invalidContent(String)
    case invalidRTCSlot(slotId: String, application: String)
    case invalidRTCSender(sender: String, memberUserId: String)
    case invalidRTCStickyKey
}

public enum MatrixRTCCallMembershipParser {
    public static func parse(event: MatrixRTCRawMembershipEvent) throws -> MatrixRTCCallMembership {
        switch event.eventType {
        case MatrixRTCRawMembershipEvent.legacyCallMemberEventType:
            return try parseLegacy(event: event)
        case MatrixRTCRawMembershipEvent.rtcMemberEventType:
            return try parseRTC(event: event)
        default:
            throw MatrixRTCCallMembershipParseError.unsupportedEventType(event.eventType)
        }
    }

    public static func activeMemberships(
        from events: [MatrixRTCRawMembershipEvent],
        for slot: MatrixRTCSlotDescription = .matrixCallRoom,
        joinedUserIds: Set<String>? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> [MatrixRTCCallMembership] {
        events.compactMap { event in
            try? parse(event: event)
        }
        .filter { membership in
            membership.slot == slot
                && !membership.isExpired(at: now)
                && (joinedUserIds?.contains(membership.userId) ?? true)
        }
        .sorted { lhs, rhs in
            if lhs.createdTimestamp == rhs.createdTimestamp {
                lhs.eventId < rhs.eventId
            } else {
                lhs.createdTimestamp < rhs.createdTimestamp
            }
        }
    }

    public static func toDeviceTargets(
        from memberships: [MatrixRTCCallMembership],
        excluding ownIdentity: MatrixRTCMembershipIdentity
    ) -> [MatrixRTCToDeviceTarget] {
        var seen = Set<MatrixRTCToDeviceTarget>()
        return memberships.compactMap { membership in
            guard membership.userId != ownIdentity.userId || membership.deviceId != ownIdentity.deviceId else {
                return nil
            }

            let target = membership.toDeviceTarget
            guard seen.insert(target).inserted else {
                return nil
            }
            return target
        }
    }
}

private extension MatrixRTCCallMembershipParser {
    static func parseLegacy(event: MatrixRTCRawMembershipEvent) throws -> MatrixRTCCallMembership {
        let content = try decode(LegacyMembershipContent.self, from: event.contentJSON)
        let slot = MatrixRTCSlotDescription.legacy(application: content.application, callId: content.callId)
        let memberId = content.membershipID ?? "\(event.sender):\(content.deviceId)"
        let identity = MatrixRTCMembershipIdentity(
            userId: event.sender,
            deviceId: content.deviceId,
            memberId: memberId
        )
        let createdTimestamp = content.createdTimestamp ?? event.originServerTimestamp
        let absoluteExpiryTimestamp = createdTimestamp
            + (content.expires ?? MatrixRTCCallMembership.defaultExpireDurationMilliseconds)

        return MatrixRTCCallMembership(
            kind: .legacyState,
            eventId: event.eventId,
            eventType: event.eventType,
            stateKey: event.stateKey,
            sender: event.sender,
            identity: identity,
            slot: slot,
            createdTimestamp: createdTimestamp,
            absoluteExpiryTimestamp: absoluteExpiryTimestamp,
            rtcBackendIdentity: MatrixRTCMembershipIdentity.legacyRTCBackendIdentity(
                userId: event.sender,
                deviceId: content.deviceId
            ),
            transports: content.fociPreferred,
            focusSelection: content.focusActive.focusSelection,
            callIntent: content.callIntent
        )
    }

    static func parseRTC(event: MatrixRTCRawMembershipEvent) throws -> MatrixRTCCallMembership {
        let content = try decode(RTCMembershipContent.self, from: event.contentJSON)
        guard content.slotId.hasPrefix("\(content.application.type)#") else {
            throw MatrixRTCCallMembershipParseError.invalidRTCSlot(
                slotId: content.slotId,
                application: content.application.type
            )
        }
        guard event.sender == content.member.userId else {
            throw MatrixRTCCallMembershipParseError.invalidRTCSender(
                sender: event.sender,
                memberUserId: content.member.userId
            )
        }
        guard content.hasValidStickyKey else {
            throw MatrixRTCCallMembershipParseError.invalidRTCStickyKey
        }

        let slot = try MatrixRTCSlotDescription(slotId: content.slotId)
        let identity = MatrixRTCMembershipIdentity(
            userId: content.member.userId,
            deviceId: content.member.deviceId,
            memberId: content.member.id
        )

        return MatrixRTCCallMembership(
            kind: .rtc,
            eventId: event.eventId,
            eventType: event.eventType,
            stateKey: event.stateKey,
            sender: event.sender,
            identity: identity,
            slot: slot,
            createdTimestamp: event.originServerTimestamp,
            absoluteExpiryTimestamp: nil,
            rtcBackendIdentity: identity.rtcBackendIdentity,
            transports: content.rtcTransports,
            focusSelection: nil,
            callIntent: content.application.callIntent
        )
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw MatrixRTCCallMembershipParseError.invalidContent(String(describing: error))
        }
    }
}

private struct LegacyMembershipContent: Decodable, Equatable, Sendable {
    let application: String
    let callId: String
    let deviceId: String
    let focusActive: LegacyFocusActive
    let fociPreferred: [MatrixRTCTransport]
    let createdTimestamp: Int64?
    let expires: Int64?
    let callIntent: String?
    let membershipID: String?

    private enum CodingKeys: String, CodingKey {
        case application
        case callId = "call_id"
        case deviceId = "device_id"
        case focusActive = "focus_active"
        case fociPreferred = "foci_preferred"
        case createdTimestamp = "created_ts"
        case expires
        case callIntent = "m.call.intent"
        case membershipID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        application = try container.decode(String.self, forKey: .application)
        callId = try container.decode(String.self, forKey: .callId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        focusActive = try container.decode(LegacyFocusActive.self, forKey: .focusActive)
        fociPreferred = try container.decodeIfPresent([MatrixRTCTransport].self, forKey: .fociPreferred) ?? []
        createdTimestamp = try container.decodeIfPresent(Int64.self, forKey: .createdTimestamp)
        expires = try container.decodeIfPresent(Int64.self, forKey: .expires)
        callIntent = try container.decodeIfPresent(String.self, forKey: .callIntent)
        membershipID = try container.decodeIfPresent(String.self, forKey: .membershipID)
    }
}

private struct LegacyFocusActive: Decodable, Equatable, Sendable {
    let type: String
    let focusSelection: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case focusSelection = "focus_selection"
    }
}

private struct RTCMembershipContent: Decodable, Equatable, Sendable {
    let slotId: String
    let member: RTCMember
    let application: RTCApplication
    let rtcTransports: [MatrixRTCTransport]
    let versions: [String]
    let msc4354StickyKey: String?
    let stickyKey: String?

    var hasValidStickyKey: Bool {
        switch (stickyKey, msc4354StickyKey) {
        case (nil, nil):
            return false
        case let (stickyKey?, msc4354StickyKey?):
            return stickyKey == msc4354StickyKey
        default:
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case slotId = "slot_id"
        case member
        case application
        case rtcTransports = "rtc_transports"
        case versions
        case msc4354StickyKey = "msc4354_sticky_key"
        case stickyKey = "sticky_key"
    }
}

private struct RTCMember: Decodable, Equatable, Sendable {
    let userId: String
    let deviceId: String
    let id: String

    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceId = "device_id"
        case id
    }
}

private struct RTCApplication: Decodable, Equatable, Sendable {
    let type: String
    let raw: [String: MatrixRTCJSONValue]

    var callIntent: String? {
        raw["m.call.intent"]?.stringValue
    }

    init(from decoder: Decoder) throws {
        let raw = try [String: MatrixRTCJSONValue](from: decoder)
        guard let type = raw["type"]?.stringValue, !type.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "MatrixRTC application is missing a string type"
            ))
        }

        self.type = type
        self.raw = raw
    }
}
