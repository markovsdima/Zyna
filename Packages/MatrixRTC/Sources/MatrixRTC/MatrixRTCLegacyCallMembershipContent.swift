import Foundation

public enum MatrixRTCLegacyCallMembershipFocusSelection: String, Codable, Sendable {
    case oldestMembership = "oldest_membership"
    case multiSFU = "multi_sfu"
}

public struct MatrixRTCLegacyCallMembershipContent: Codable, Equatable, Sendable {
    public let application: String
    public let callId: String
    public let scope: String
    public let deviceId: String
    public let focusActive: FocusActive
    public let fociPreferred: [MatrixRTCTransport]
    public let createdTimestamp: Int64?
    public let expires: Int64
    public let callIntent: String?
    public let membershipID: String

    public init(
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        deviceId: String,
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection,
        fociPreferred: [MatrixRTCTransport],
        createdTimestamp: Int64?,
        expires: Int64 = MatrixRTCCallMembership.defaultExpireDurationMilliseconds,
        callIntent: String?,
        membershipID: String
    ) {
        self.application = slot.application
        self.callId = slot.legacyCallId
        self.scope = "m.room"
        self.deviceId = deviceId
        self.focusActive = .init(type: "livekit", focusSelection: focusSelection)
        self.fociPreferred = fociPreferred
        self.createdTimestamp = createdTimestamp
        self.expires = expires
        self.callIntent = callIntent
        self.membershipID = membershipID
    }

    public init(contentJSON: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentJSON.utf8))
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MatrixRTCLegacyCallMembershipContentError.invalidUTF8
        }
        return json
    }

    private enum CodingKeys: String, CodingKey {
        case application
        case callId = "call_id"
        case scope
        case deviceId = "device_id"
        case focusActive = "focus_active"
        case fociPreferred = "foci_preferred"
        case createdTimestamp = "created_ts"
        case expires
        case callIntent = "m.call.intent"
        case membershipID
    }
}

public extension MatrixRTCLegacyCallMembershipContent {
    struct FocusActive: Codable, Equatable, Sendable {
        public let type: String
        public let focusSelection: MatrixRTCLegacyCallMembershipFocusSelection

        public init(type: String, focusSelection: MatrixRTCLegacyCallMembershipFocusSelection) {
            self.type = type
            self.focusSelection = focusSelection
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case focusSelection = "focus_selection"
        }
    }
}

public enum MatrixRTCLegacyCallMembershipContentError: Error, Equatable {
    case invalidUTF8
}

public struct MatrixRTCLegacyCallMembershipStateEvent: Equatable, Sendable {
    public static let leaveContentJSON = "{}"

    public let identity: MatrixRTCMembershipIdentity
    public let stateKey: String
    public let content: MatrixRTCLegacyCallMembershipContent

    public init(
        userId: String,
        deviceId: String,
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        roomVersion: String? = nil,
        focusSelection: MatrixRTCLegacyCallMembershipFocusSelection,
        fociPreferred: [MatrixRTCTransport],
        createdTimestamp: Int64?,
        expires: Int64 = MatrixRTCCallMembership.defaultExpireDurationMilliseconds,
        callIntent: String?
    ) {
        let membershipID = MatrixRTCMembershipIdentity.legacyRTCBackendIdentity(
            userId: userId,
            deviceId: deviceId
        )
        self.identity = .init(userId: userId, deviceId: deviceId, memberId: membershipID)
        self.stateKey = Self.stateKey(
            userId: userId,
            deviceId: deviceId,
            slot: slot,
            roomVersion: roomVersion
        )
        self.content = .init(
            slot: slot,
            deviceId: deviceId,
            focusSelection: focusSelection,
            fociPreferred: fociPreferred,
            createdTimestamp: createdTimestamp,
            expires: expires,
            callIntent: callIntent,
            membershipID: membershipID
        )
    }

    public func contentJSON() throws -> String {
        try content.jsonString()
    }

    public static func stateKey(
        userId: String,
        deviceId: String,
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        roomVersion: String? = nil
    ) -> String {
        let base = "\(userId)_\(deviceId)_\(slot.application)\(slot.legacyCallId)"
        guard shouldPrefixStateKey(roomVersion: roomVersion) else {
            return base
        }
        return "_\(base)"
    }

    private static func shouldPrefixStateKey(roomVersion: String?) -> Bool {
        guard let roomVersion else {
            return true
        }

        return roomVersion.range(
            of: #"^org\.matrix\.msc(3757|3779)\b"#,
            options: .regularExpression
        ) == nil
    }
}
