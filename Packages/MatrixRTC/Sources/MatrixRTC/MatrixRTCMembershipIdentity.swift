import CryptoKit
import Foundation

public struct MatrixRTCMembershipIdentity: Equatable, Hashable, Sendable {
    public let userId: String
    public let deviceId: String
    public let memberId: String

    public init(userId: String, deviceId: String, memberId: String) {
        self.userId = userId
        self.deviceId = deviceId
        self.memberId = memberId
    }

    public var rtcBackendIdentity: String {
        Self.rtcBackendIdentity(userId: userId, deviceId: deviceId, memberId: memberId)
    }

    public var legacyRTCBackendIdentity: String {
        Self.legacyRTCBackendIdentity(userId: userId, deviceId: deviceId)
    }

    public static func rtcBackendIdentity(userId: String, deviceId: String, memberId: String) -> String {
        let payload = encodeIdentityPayload(userId: userId, deviceId: deviceId, memberId: memberId)
        let digest = SHA256.hash(data: payload)
        return Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public static func legacyRTCBackendIdentity(userId: String, deviceId: String) -> String {
        "\(userId):\(deviceId)"
    }

    private static func encodeIdentityPayload(userId: String, deviceId: String, memberId: String) -> Data {
        let payload = [userId, deviceId, memberId]
        do {
            return try JSONEncoder().encode(payload)
        } catch {
            preconditionFailure("Failed to encode MatrixRTC membership identity payload: \(error)")
        }
    }
}
