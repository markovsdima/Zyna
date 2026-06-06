import Foundation

public struct MatrixRTCSlotDescription: Codable, Equatable, Hashable, Sendable {
    public static let matrixCallRoom = Self(application: "m.call", id: "ROOM")

    public let application: String
    public let id: String

    public init(application: String, id: String) {
        self.application = application
        self.id = id
    }

    public init(slotId: String) throws {
        guard let separator = slotId.firstIndex(of: "#") else {
            throw MatrixRTCSlotDescriptionError.invalidSlotId(slotId)
        }

        let application = String(slotId[..<separator])
        let id = String(slotId[slotId.index(after: separator)...])
        guard !application.isEmpty, !id.isEmpty else {
            throw MatrixRTCSlotDescriptionError.invalidSlotId(slotId)
        }

        self.application = application
        self.id = id
    }

    public var slotId: String {
        "\(application)#\(id)"
    }

    public var legacyCallId: String {
        application == "m.call" && id == "ROOM" ? "" : id
    }

    public static func legacy(application: String, callId: String) -> Self {
        Self(
            application: application,
            id: application == "m.call" && callId.isEmpty ? "ROOM" : callId
        )
    }
}

public enum MatrixRTCSlotDescriptionError: Error, Equatable {
    case invalidSlotId(String)
}
