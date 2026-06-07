import Foundation
import MatrixRTC

public struct MatrixRTCLiveKitOpenIDToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let matrixServerName: String
    public let expiresIn: UInt64

    public init(
        accessToken: String,
        tokenType: String,
        matrixServerName: String,
        expiresIn: UInt64
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.matrixServerName = matrixServerName
        self.expiresIn = expiresIn
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case matrixServerName = "matrix_server_name"
        case expiresIn = "expires_in"
    }
}

public struct MatrixRTCLiveKitSFUConfig: Equatable, Sendable {
    public let url: String
    public let jwt: String
    public let liveKitAlias: String
    public let liveKitIdentity: String

    public init(
        url: String,
        jwt: String,
        liveKitAlias: String,
        liveKitIdentity: String
    ) {
        self.url = url
        self.jwt = jwt
        self.liveKitAlias = liveKitAlias
        self.liveKitIdentity = liveKitIdentity
    }
}

public enum MatrixRTCLiveKitJWTEndpointVersion: Equatable, Sendable {
    case legacy
    case matrix2
    case matrix2WithLegacyFallback
}

public struct MatrixRTCLiveKitDelayDelegation: Equatable, Sendable {
    public let endpointBaseURL: String
    public let delayId: String
    public let delayTimeoutMilliseconds: Int

    public init(
        endpointBaseURL: String,
        delayId: String,
        delayTimeoutMilliseconds: Int
    ) {
        self.endpointBaseURL = endpointBaseURL
        self.delayId = delayId
        self.delayTimeoutMilliseconds = delayTimeoutMilliseconds
    }
}

public enum MatrixRTCLiveKitSFUClientError: Error, Equatable {
    case invalidServiceURL(String)
    case invalidResponse
    case httpStatus(Int)
    case unsupportedMatrix2Endpoint(Int)
    case invalidJWT
    case missingJWTPayload
}

public protocol MatrixRTCLiveKitURLLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: MatrixRTCLiveKitURLLoading {}

public final class MatrixRTCLiveKitSFUClient: @unchecked Sendable {
    private let urlLoader: any MatrixRTCLiveKitURLLoading
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    public init(
        urlLoader: any MatrixRTCLiveKitURLLoading = URLSession.shared,
        jsonEncoder: JSONEncoder = JSONEncoder(),
        jsonDecoder: JSONDecoder = JSONDecoder()
    ) {
        self.urlLoader = urlLoader
        self.jsonEncoder = jsonEncoder
        self.jsonDecoder = jsonDecoder
    }

    public func sfuConfig(
        openIDTokenProvider: @Sendable () async throws -> MatrixRTCLiveKitOpenIDToken,
        membership: MatrixRTCMembershipIdentity,
        serviceURL: String,
        roomId: String,
        endpointVersion: MatrixRTCLiveKitJWTEndpointVersion = .legacy,
        delayDelegation: MatrixRTCLiveKitDelayDelegation? = nil
    ) async throws -> MatrixRTCLiveKitSFUConfig {
        let openIDToken = try await openIDTokenProvider()
        return try await sfuConfig(
            openIDToken: openIDToken,
            membership: membership,
            serviceURL: serviceURL,
            roomId: roomId,
            endpointVersion: endpointVersion,
            delayDelegation: delayDelegation
        )
    }

    public func sfuConfig(
        openIDToken: MatrixRTCLiveKitOpenIDToken,
        membership: MatrixRTCMembershipIdentity,
        serviceURL: String,
        roomId: String,
        endpointVersion: MatrixRTCLiveKitJWTEndpointVersion = .legacy,
        delayDelegation: MatrixRTCLiveKitDelayDelegation? = nil
    ) async throws -> MatrixRTCLiveKitSFUConfig {
        switch endpointVersion {
        case .legacy:
            return try await legacySFUConfig(
                openIDToken: openIDToken,
                deviceId: membership.deviceId,
                serviceURL: serviceURL,
                roomId: roomId,
                delayDelegation: delayDelegation
            )
        case .matrix2:
            return try await matrix2SFUConfig(
                openIDToken: openIDToken,
                membership: membership,
                serviceURL: serviceURL,
                roomId: roomId,
                delayDelegation: delayDelegation
            )
        case .matrix2WithLegacyFallback:
            do {
                return try await matrix2SFUConfig(
                    openIDToken: openIDToken,
                    membership: membership,
                    serviceURL: serviceURL,
                    roomId: roomId,
                    delayDelegation: delayDelegation
                )
            } catch {
                return try await legacySFUConfig(
                    openIDToken: openIDToken,
                    deviceId: membership.deviceId,
                    serviceURL: serviceURL,
                    roomId: roomId,
                    delayDelegation: delayDelegation
                )
            }
        }
    }
}

private extension MatrixRTCLiveKitSFUClient {
    func matrix2SFUConfig(
        openIDToken: MatrixRTCLiveKitOpenIDToken,
        membership: MatrixRTCMembershipIdentity,
        serviceURL: String,
        roomId: String,
        delayDelegation: MatrixRTCLiveKitDelayDelegation?
    ) async throws -> MatrixRTCLiveKitSFUConfig {
        let body = Matrix2JWTRequest(
            roomId: roomId,
            slotId: MatrixRTCSlotDescription.matrixCallRoom.slotId,
            openIDToken: openIDToken,
            member: .init(
                id: membership.memberId,
                claimedUserId: membership.userId,
                claimedDeviceId: membership.deviceId
            ),
            delayDelegation: delayDelegation
        )
        do {
            return try await requestSFUConfig(
                serviceURL: serviceURL,
                endpointPath: "get_token",
                body: body
            )
        } catch MatrixRTCLiveKitSFUClientError.httpStatus(let status) where status == 404 {
            throw MatrixRTCLiveKitSFUClientError.unsupportedMatrix2Endpoint(status)
        }
    }

    func legacySFUConfig(
        openIDToken: MatrixRTCLiveKitOpenIDToken,
        deviceId: String,
        serviceURL: String,
        roomId: String,
        delayDelegation: MatrixRTCLiveKitDelayDelegation?
    ) async throws -> MatrixRTCLiveKitSFUConfig {
        let body = LegacyJWTRequest(
            room: roomId,
            openIDToken: openIDToken,
            deviceId: deviceId,
            delayDelegation: delayDelegation
        )
        return try await requestSFUConfig(
            serviceURL: serviceURL,
            endpointPath: "sfu/get",
            body: body
        )
    }

    func requestSFUConfig<Body: Encodable>(
        serviceURL: String,
        endpointPath: String,
        body: Body
    ) async throws -> MatrixRTCLiveKitSFUConfig {
        let url = try endpointURL(serviceURL: serviceURL, endpointPath: endpointPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonEncoder.encode(body)

        let (data, response) = try await urlLoader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixRTCLiveKitSFUClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MatrixRTCLiveKitSFUClientError.httpStatus(http.statusCode)
        }

        let responseBody = try jsonDecoder.decode(SFUConfigResponse.self, from: data)
        let tokenPayload = try Self.decodeJWTPayload(responseBody.jwt)
        return .init(
            url: responseBody.url,
            jwt: responseBody.jwt,
            liveKitAlias: tokenPayload.video.room,
            liveKitIdentity: tokenPayload.sub
        )
    }

    func endpointURL(serviceURL: String, endpointPath: String) throws -> URL {
        var raw = serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              components.host != nil,
              scheme == "http" || scheme == "https" else {
            throw MatrixRTCLiveKitSFUClientError.invalidServiceURL(serviceURL)
        }

        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = endpointPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MatrixRTCLiveKitSFUClientError.invalidServiceURL(serviceURL)
        }
        return url
    }

    static func decodeJWTPayload(_ jwt: String) throws -> SFUJWTPayload {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            throw MatrixRTCLiveKitSFUClientError.invalidJWT
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: payload) else {
            throw MatrixRTCLiveKitSFUClientError.invalidJWT
        }

        do {
            return try JSONDecoder().decode(SFUJWTPayload.self, from: data)
        } catch {
            throw MatrixRTCLiveKitSFUClientError.missingJWTPayload
        }
    }
}

private struct SFUConfigResponse: Decodable {
    let url: String
    let jwt: String
}

private struct SFUJWTPayload: Decodable {
    struct Video: Decodable {
        let room: String
    }

    let sub: String
    let video: Video
}

private struct Matrix2JWTRequest: Encodable {
    let roomId: String
    let slotId: String
    let openIDToken: MatrixRTCLiveKitOpenIDToken
    let member: Member
    let delayDelegation: MatrixRTCLiveKitDelayDelegation?

    private enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case slotId = "slot_id"
        case openIDToken = "openid_token"
        case member
        case delayId = "delay_id"
        case delayTimeout = "delay_timeout"
        case delayEndpointBaseURL = "delay_cs_api_url"
    }

    struct Member: Encodable {
        let id: String
        let claimedUserId: String
        let claimedDeviceId: String

        private enum CodingKeys: String, CodingKey {
            case id
            case claimedUserId = "claimed_user_id"
            case claimedDeviceId = "claimed_device_id"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(slotId, forKey: .slotId)
        try container.encode(openIDToken, forKey: .openIDToken)
        try container.encode(member, forKey: .member)
        try encodeDelayDelegation(delayDelegation, to: &container)
    }
}

private struct LegacyJWTRequest: Encodable {
    let room: String
    let openIDToken: MatrixRTCLiveKitOpenIDToken
    let deviceId: String
    let delayDelegation: MatrixRTCLiveKitDelayDelegation?

    private enum CodingKeys: String, CodingKey {
        case room
        case openIDToken = "openid_token"
        case deviceId = "device_id"
        case delayId = "delay_id"
        case delayTimeout = "delay_timeout"
        case delayEndpointBaseURL = "delay_cs_api_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(room, forKey: .room)
        try container.encode(openIDToken, forKey: .openIDToken)
        try container.encode(deviceId, forKey: .deviceId)
        try encodeDelayDelegation(delayDelegation, to: &container)
    }
}

private func encodeDelayDelegation<Key: CodingKey>(
    _ delayDelegation: MatrixRTCLiveKitDelayDelegation?,
    to container: inout KeyedEncodingContainer<Key>
) throws {
    guard let delayDelegation,
          let delayIdKey = Key(stringValue: "delay_id"),
          let delayTimeoutKey = Key(stringValue: "delay_timeout"),
          let delayEndpointBaseURLKey = Key(stringValue: "delay_cs_api_url") else {
        return
    }

    try container.encode(delayDelegation.delayId, forKey: delayIdKey)
    try container.encode(delayDelegation.delayTimeoutMilliseconds, forKey: delayTimeoutKey)
    try container.encode(delayDelegation.endpointBaseURL, forKey: delayEndpointBaseURLKey)
}
