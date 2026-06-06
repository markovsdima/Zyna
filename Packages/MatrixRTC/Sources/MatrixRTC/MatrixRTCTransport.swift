import Foundation

public struct MatrixRTCTransport: Codable, Equatable, Sendable {
    public let type: String
    public let raw: [String: MatrixRTCJSONValue]

    public init(type: String, raw: [String: MatrixRTCJSONValue] = [:]) {
        var raw = raw
        raw["type"] = .string(type)

        self.type = type
        self.raw = raw
    }

    public var liveKitServiceURL: String? {
        raw["livekit_service_url"]?.stringValue
    }

    public init(from decoder: Decoder) throws {
        let raw = try [String: MatrixRTCJSONValue](from: decoder)
        guard let type = raw["type"]?.stringValue, !type.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "MatrixRTC transport is missing a string type"
            ))
        }

        self.type = type
        self.raw = raw
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }
}
