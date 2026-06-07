import Foundation
import MatrixRTCLiveKit
import Testing

@Test func discoversBackendRTCTransportFirst() async throws {
    let loader = DiscoveryMockURLLoader(responses: [
        .success(discoveryJSONResponse([
            "rtc_transports": [
                [
                    "type": "livekit",
                    "livekit_service_url": "https://backend-livekit.example.org",
                ],
            ],
        ])),
    ])
    let client = MatrixRTCLiveKitTransportDiscoveryClient(urlLoader: loader)

    let discovered = try #require(await client.discoverPreferredTransport(
        homeserverURL: "https://matrix.example.org/",
        accessToken: "matrix-access",
        serverName: "example.org",
        fallbackServiceURL: "https://fallback-livekit.example.org"
    ))

    #expect(discovered.source == .backend)
    #expect(discovered.transport.liveKitServiceURL == "https://backend-livekit.example.org")
    #expect(loader.requests.map(\.url?.absoluteString) == [
        "https://matrix.example.org/_matrix/client/unstable/org.matrix.msc4143/rtc/transports"
    ])
    #expect(loader.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer matrix-access")
}

@Test func fallsBackToWellKnownRTCTransport() async throws {
    let loader = DiscoveryMockURLLoader(responses: [
        .success(discoveryEmptyResponse(statusCode: 404)),
        .success(discoveryJSONResponse([
            "org.matrix.msc4143.rtc_foci": [
                [
                    "type": "livekit",
                    "livekit_service_url": "https://well-known-livekit.example.org",
                ],
            ],
        ])),
    ])
    let client = MatrixRTCLiveKitTransportDiscoveryClient(urlLoader: loader)

    let discovered = try #require(await client.discoverPreferredTransport(
        homeserverURL: "https://matrix.example.org",
        accessToken: "matrix-access",
        serverName: "example.org"
    ))

    #expect(discovered.source == .wellKnown)
    #expect(discovered.transport.liveKitServiceURL == "https://well-known-livekit.example.org")
    #expect(loader.requests.map(\.url?.absoluteString) == [
        "https://matrix.example.org/_matrix/client/unstable/org.matrix.msc4143/rtc/transports",
        "https://example.org/.well-known/matrix/client",
    ])
}

@Test func fallsBackToConfiguredRTCTransportLast() async throws {
    let loader = DiscoveryMockURLLoader(responses: [
        .success(discoveryEmptyResponse(statusCode: 500)),
        .success(discoveryEmptyResponse(statusCode: 404)),
    ])
    let client = MatrixRTCLiveKitTransportDiscoveryClient(urlLoader: loader)

    let discovered = try #require(await client.discoverPreferredTransport(
        homeserverURL: "https://matrix.example.org",
        accessToken: "matrix-access",
        serverName: "example.org",
        fallbackServiceURL: "https://fallback-livekit.example.org"
    ))

    #expect(discovered.source == .fallback)
    #expect(discovered.transport.liveKitServiceURL == "https://fallback-livekit.example.org")
}

private final class DiscoveryMockURLLoader: MatrixRTCLiveKitURLLoading, @unchecked Sendable {
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

private func discoveryJSONResponse(_ body: [String: Any], statusCode: Int = 200) -> (Data, URLResponse) {
    let url = URL(string: "https://matrix.example.org")!
    let data = try! JSONSerialization.data(withJSONObject: body)
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (data, response)
}

private func discoveryEmptyResponse(statusCode: Int) -> (Data, URLResponse) {
    let url = URL(string: "https://matrix.example.org")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (Data(), response)
}
