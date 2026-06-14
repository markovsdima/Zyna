import Foundation

public struct MatrixRTCCallEncryptionKeysContent: Codable, Equatable, Sendable {
    public static let eventType = "io.element.call.encryption_keys"

    public let keys: Keys
    public let member: Member
    public let roomId: String
    public let session: Session
    public let sentTimestamp: Int64?

    public init(
        keys: Keys,
        member: Member,
        roomId: String,
        session: Session = .matrixCallRoom,
        sentTimestamp: Int64?
    ) {
        self.keys = keys
        self.member = member
        self.roomId = roomId
        self.session = session
        self.sentTimestamp = sentTimestamp
    }

    public init(contentJSON: String) throws {
        let data = Data(contentJSON.utf8)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MatrixRTCCallEncryptionKeysContentError.invalidUTF8
        }
        return json
    }

    private enum CodingKeys: String, CodingKey {
        case keys
        case member
        case roomId = "room_id"
        case session
        case sentTimestamp = "sent_ts"
    }
}

public extension MatrixRTCCallEncryptionKeysContent {
    struct Keys: Codable, Equatable, Sendable {
        public let index: Int
        public let key: String

        public init(index: Int, key: String) {
            self.index = index
            self.key = key
        }
    }

    struct Member: Codable, Equatable, Sendable {
        public let id: String?
        public let claimedDeviceId: String

        public init(id: String?, claimedDeviceId: String) {
            self.id = id
            self.claimedDeviceId = claimedDeviceId
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case claimedDeviceId = "claimed_device_id"
        }
    }

    struct Session: Codable, Equatable, Sendable {
        public static let matrixCallRoom = Self(application: "m.call", callId: "", scope: "m.room")

        public let application: String
        public let callId: String
        public let scope: String

        public init(application: String, callId: String, scope: String) {
            self.application = application
            self.callId = callId
            self.scope = scope
        }

        private enum CodingKeys: String, CodingKey {
            case application
            case callId = "call_id"
            case scope
        }
    }
}

public enum MatrixRTCCallEncryptionKeysContentError: Error, Equatable {
    case invalidUTF8
}
