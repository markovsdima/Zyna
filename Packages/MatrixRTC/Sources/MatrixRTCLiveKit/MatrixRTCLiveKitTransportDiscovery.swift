import Foundation
import MatrixRTC

public enum MatrixRTCLiveKitTransportDiscoverySource: Equatable, Sendable {
    case backend
    case wellKnown
    case fallback
}

public struct MatrixRTCLiveKitDiscoveredTransport: Equatable, Sendable {
    public let transport: MatrixRTCTransport
    public let source: MatrixRTCLiveKitTransportDiscoverySource

    public init(
        transport: MatrixRTCTransport,
        source: MatrixRTCLiveKitTransportDiscoverySource
    ) {
        self.transport = transport
        self.source = source
    }
}

public enum MatrixRTCLiveKitTransportDiscoveryError: Error, Equatable {
    case invalidHomeserverURL(String)
    case invalidServerName(String)
    case invalidResponse
}

public final class MatrixRTCLiveKitTransportDiscoveryClient: @unchecked Sendable {
    private let urlLoader: any MatrixRTCLiveKitURLLoading
    private let jsonDecoder: JSONDecoder

    public init(
        urlLoader: any MatrixRTCLiveKitURLLoading = URLSession.shared,
        jsonDecoder: JSONDecoder = JSONDecoder()
    ) {
        self.urlLoader = urlLoader
        self.jsonDecoder = jsonDecoder
    }

    public func discoverPreferredTransport(
        homeserverURL: String,
        accessToken: String?,
        serverName: String?,
        fallbackServiceURL: String? = nil
    ) async -> MatrixRTCLiveKitDiscoveredTransport? {
        if let accessToken,
           let transport = try? await backendTransport(
                homeserverURL: homeserverURL,
                accessToken: accessToken
           ) {
            return .init(transport: transport, source: .backend)
        }

        if let serverName,
           let transport = try? await wellKnownTransport(serverName: serverName) {
            return .init(transport: transport, source: .wellKnown)
        }

        guard let fallbackServiceURL, !fallbackServiceURL.isEmpty else {
            return nil
        }

        return .init(
            transport: .liveKit(serviceURL: fallbackServiceURL),
            source: .fallback
        )
    }
}

private extension MatrixRTCLiveKitTransportDiscoveryClient {
    func backendTransport(
        homeserverURL: String,
        accessToken: String
    ) async throws -> MatrixRTCTransport? {
        let url = try matrixURL(
            homeserverURL: homeserverURL,
            percentEncodedPath: "/_matrix/client/unstable/org.matrix.msc4143/rtc/transports"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlLoader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixRTCLiveKitTransportDiscoveryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            return nil
        }

        let body = try jsonDecoder.decode(BackendTransportsResponse.self, from: data)
        return body.rtcTransports.first(where: Self.isUsableLiveKitTransport)
    }

    func wellKnownTransport(serverName: String) async throws -> MatrixRTCTransport? {
        let url = try wellKnownURL(serverName: serverName)
        let (data, response) = try await urlLoader.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            throw MatrixRTCLiveKitTransportDiscoveryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            return nil
        }

        let body = try jsonDecoder.decode([String: MatrixRTCJSONValue].self, from: data)
        guard case let .array(foci)? = body["org.matrix.msc4143.rtc_foci"] else {
            return nil
        }

        return foci.compactMap { value -> MatrixRTCTransport? in
            guard case let .object(raw) = value,
                  let type = raw["type"]?.stringValue else {
                return nil
            }
            return MatrixRTCTransport(type: type, raw: raw)
        }.first(where: Self.isUsableLiveKitTransport)
    }

    func matrixURL(homeserverURL: String, percentEncodedPath: String) throws -> URL {
        var raw = homeserverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              components.host != nil,
              scheme == "http" || scheme == "https" else {
            throw MatrixRTCLiveKitTransportDiscoveryError.invalidHomeserverURL(homeserverURL)
        }

        components.percentEncodedPath = percentEncodedPath
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MatrixRTCLiveKitTransportDiscoveryError.invalidHomeserverURL(homeserverURL)
        }
        return url
    }

    func wellKnownURL(serverName: String) throws -> URL {
        let raw = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              var components = URLComponents(string: "https://\(raw)") else {
            throw MatrixRTCLiveKitTransportDiscoveryError.invalidServerName(serverName)
        }

        components.percentEncodedPath = "/.well-known/matrix/client"
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MatrixRTCLiveKitTransportDiscoveryError.invalidServerName(serverName)
        }
        return url
    }

    static func isUsableLiveKitTransport(_ transport: MatrixRTCTransport) -> Bool {
        transport.type == "livekit" && transport.liveKitServiceURL != nil
    }
}

private struct BackendTransportsResponse: Decodable {
    let rtcTransports: [MatrixRTCTransport]

    private enum CodingKeys: String, CodingKey {
        case rtcTransports = "rtc_transports"
    }
}
