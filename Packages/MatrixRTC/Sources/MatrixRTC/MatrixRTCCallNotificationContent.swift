import Foundation

public enum MatrixRTCCallNotificationType: String, Codable, Sendable {
    case ring
    case notification
}

public struct MatrixRTCCallNotificationContent: Codable, Equatable, Sendable {
    public static let eventType = "org.matrix.msc4075.rtc.notification"

    public let mentions: Mentions?
    public let notificationType: MatrixRTCCallNotificationType
    public let relation: Relation
    public let senderTimestamp: Int64
    public let lifetime: Int64
    public let callIntent: String?

    public init(
        parentEventId: String,
        notificationType: MatrixRTCCallNotificationType,
        senderTimestamp: Int64,
        lifetime: Int64 = 30_000,
        callIntent: String?,
        mentions: Mentions? = .roomWide
    ) {
        self.mentions = mentions
        self.notificationType = notificationType
        self.relation = .reference(eventId: parentEventId)
        self.senderTimestamp = senderTimestamp
        self.lifetime = lifetime
        self.callIntent = callIntent
    }

    public init(contentJSON: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentJSON.utf8))
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MatrixRTCCallNotificationContentError.invalidUTF8
        }
        return json
    }

    private enum CodingKeys: String, CodingKey {
        case mentions = "m.mentions"
        case notificationType = "notification_type"
        case relation = "m.relates_to"
        case senderTimestamp = "sender_ts"
        case lifetime
        case callIntent = "m.call.intent"
    }
}

public extension MatrixRTCCallNotificationContent {
    struct Mentions: Codable, Equatable, Sendable {
        public static let roomWide = Self(userIds: [], room: true)

        public let userIds: [String]
        public let room: Bool

        public init(userIds: [String], room: Bool) {
            self.userIds = userIds
            self.room = room
        }

        private enum CodingKeys: String, CodingKey {
            case userIds = "user_ids"
            case room
        }
    }

    struct Relation: Codable, Equatable, Sendable {
        public static func reference(eventId: String) -> Self {
            .init(eventId: eventId, relType: "m.reference")
        }

        public let eventId: String
        public let relType: String

        public init(eventId: String, relType: String) {
            self.eventId = eventId
            self.relType = relType
        }

        private enum CodingKeys: String, CodingKey {
            case eventId = "event_id"
            case relType = "rel_type"
        }
    }
}

public struct MatrixRTCLegacyCallNotifyContent: Codable, Equatable, Sendable {
    public static let eventType = "org.matrix.msc4075.call.notify"

    public let application: String
    public let mentions: MatrixRTCCallNotificationContent.Mentions
    public let notifyType: String
    public let callId: String

    public init(
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        notificationType: MatrixRTCCallNotificationType,
        mentions: MatrixRTCCallNotificationContent.Mentions = .roomWide
    ) {
        self.application = slot.application
        self.mentions = mentions
        notifyType = notificationType == .notification ? "notify" : notificationType.rawValue
        callId = slot.id
    }

    public init(contentJSON: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(contentJSON.utf8))
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MatrixRTCCallNotificationContentError.invalidUTF8
        }
        return json
    }

    private enum CodingKeys: String, CodingKey {
        case application
        case mentions = "m.mentions"
        case notifyType = "notify_type"
        case callId = "call_id"
    }
}

public enum MatrixRTCCallNotificationContentError: Error, Equatable {
    case invalidUTF8
}
