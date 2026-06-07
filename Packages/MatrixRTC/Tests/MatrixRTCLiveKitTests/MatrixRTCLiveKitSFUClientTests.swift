import Foundation
import MatrixRTC
@testable import MatrixRTCLiveKit
import Testing

@Test func fetchesLegacySFUConfigWithElementCallCompatibleBody() async throws {
    let jwt = testJWT(liveKitAlias: "!room:example.org", liveKitIdentity: "@alice:example.org:ALICEDEVICE")
    let loader = MockURLLoader(responses: [
        .success(jsonResponse(["url": "wss://livekit.example.org", "jwt": jwt]))
    ])
    let client = MatrixRTCLiveKitSFUClient(urlLoader: loader)

    let config = try await client.sfuConfig(
        openIDToken: openIDToken,
        membership: membership,
        serviceURL: "https://matrix-rtc.example.org/livekit/jwt/",
        roomId: "!room:example.org"
    )

    #expect(config.url == "wss://livekit.example.org")
    #expect(config.jwt == jwt)
    #expect(config.liveKitAlias == "!room:example.org")
    #expect(config.liveKitIdentity == "@alice:example.org:ALICEDEVICE")
    #expect(loader.requests.map(\.url?.absoluteString) == [
        "https://matrix-rtc.example.org/livekit/jwt/sfu/get"
    ])

    let body = try requestBody(loader.requests[0])
    #expect(body["room"] as? String == "!room:example.org")
    #expect(body["device_id"] as? String == "ALICEDEVICE")

    let token = try #require(body["openid_token"] as? [String: Any])
    #expect(token["access_token"] as? String == "openid-access")
    #expect(token["token_type"] as? String == "Bearer")
    #expect(token["matrix_server_name"] as? String == "example.org")
    #expect(token["expires_in"] as? Int == 3600)
}

@Test func fetchesMatrix2SFUConfigWithMemberIdentityAndDelayDelegation() async throws {
    let jwt = testJWT(liveKitAlias: "lk-alias", liveKitIdentity: "hashed-livekit-identity")
    let loader = MockURLLoader(responses: [
        .success(jsonResponse(["url": "wss://livekit.example.org", "jwt": jwt]))
    ])
    let client = MatrixRTCLiveKitSFUClient(urlLoader: loader)

    let config = try await client.sfuConfig(
        openIDToken: openIDToken,
        membership: membership,
        serviceURL: "https://matrix-rtc.example.org",
        roomId: "!room:example.org",
        endpointVersion: .matrix2,
        delayDelegation: .init(
            endpointBaseURL: "https://matrix.example.org",
            delayId: "delay-id",
            delayTimeoutMilliseconds: 10_000
        )
    )

    #expect(config.liveKitAlias == "lk-alias")
    #expect(config.liveKitIdentity == "hashed-livekit-identity")
    #expect(loader.requests.map(\.url?.absoluteString) == [
        "https://matrix-rtc.example.org/get_token"
    ])

    let body = try requestBody(loader.requests[0])
    #expect(body["room_id"] as? String == "!room:example.org")
    #expect(body["slot_id"] as? String == "m.call#ROOM")
    #expect(body["delay_id"] as? String == "delay-id")
    #expect(body["delay_timeout"] as? Int == 10_000)
    #expect(body["delay_cs_api_url"] as? String == "https://matrix.example.org")

    let member = try #require(body["member"] as? [String: Any])
    #expect(member["id"] as? String == "@alice:example.org:ALICEDEVICE")
    #expect(member["claimed_user_id"] as? String == "@alice:example.org")
    #expect(member["claimed_device_id"] as? String == "ALICEDEVICE")
}

@Test func fallsBackFromMatrix2EndpointToLegacyEndpoint() async throws {
    let jwt = testJWT(liveKitAlias: "!room:example.org", liveKitIdentity: "@alice:example.org:ALICEDEVICE")
    let loader = MockURLLoader(responses: [
        .success(emptyResponse(statusCode: 404)),
        .success(jsonResponse(["url": "wss://legacy-livekit.example.org", "jwt": jwt])),
    ])
    let client = MatrixRTCLiveKitSFUClient(urlLoader: loader)

    let config = try await client.sfuConfig(
        openIDToken: openIDToken,
        membership: membership,
        serviceURL: "https://matrix-rtc.example.org",
        roomId: "!room:example.org",
        endpointVersion: .matrix2WithLegacyFallback
    )

    #expect(config.url == "wss://legacy-livekit.example.org")
    #expect(loader.requests.map(\.url?.absoluteString) == [
        "https://matrix-rtc.example.org/get_token",
        "https://matrix-rtc.example.org/sfu/get",
    ])
}

@Test func reportsUnsupportedMatrix2EndpointWhenForced() async throws {
    let loader = MockURLLoader(responses: [
        .success(emptyResponse(statusCode: 404))
    ])
    let client = MatrixRTCLiveKitSFUClient(urlLoader: loader)

    await #expect(throws: MatrixRTCLiveKitSFUClientError.unsupportedMatrix2Endpoint(404)) {
        try await client.sfuConfig(
            openIDToken: openIDToken,
            membership: membership,
            serviceURL: "https://matrix-rtc.example.org",
            roomId: "!room:example.org",
            endpointVersion: .matrix2
        )
    }
}

private let openIDToken = MatrixRTCLiveKitOpenIDToken(
    accessToken: "openid-access",
    tokenType: "Bearer",
    matrixServerName: "example.org",
    expiresIn: 3600
)

private let membership = MatrixRTCMembershipIdentity(
    userId: "@alice:example.org",
    deviceId: "ALICEDEVICE",
    memberId: "@alice:example.org:ALICEDEVICE"
)

private final class MockURLLoader: MatrixRTCLiveKitURLLoading, @unchecked Sendable {
    enum Response {
        case success((Data, URLResponse))
        case failure(Error)
    }

    private(set) var requests: [URLRequest] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        switch response {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func jsonResponse(_ body: [String: String], statusCode: Int = 200) -> (Data, URLResponse) {
    let url = URL(string: "https://matrix-rtc.example.org")!
    let data = try! JSONSerialization.data(withJSONObject: body)
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (data, response)
}

private func emptyResponse(statusCode: Int) -> (Data, URLResponse) {
    let url = URL(string: "https://matrix-rtc.example.org")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (Data(), response)
}

private func testJWT(liveKitAlias: String, liveKitIdentity: String) -> String {
    let header = base64URLString(data: #"{"alg":"none","typ":"JWT"}"#.data(using: .utf8)!)
    let payload = base64URLString(data: """
    {
      "sub": "\(liveKitIdentity)",
      "video": {
        "room": "\(liveKitAlias)"
      }
    }
    """.data(using: .utf8)!)
    return "\(header).\(payload).signature"
}

private func base64URLString(data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
