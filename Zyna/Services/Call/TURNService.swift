//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import WebRTC
import MatrixRustSDK

private let logCall = ScopedLog(.call)

// MARK: - TURN Service

/// Fetches TURN credentials from the Matrix homeserver and caches them
/// until the TTL expires.
final class TURNService {

    static let shared = TURNService()

    private var cached: CachedTURN?
    private let lock = NSLock()

    private init() {}

    // MARK: - Public

    /// Returns ICE servers including TURN credentials from the homeserver.
    /// Falls back to STUN-only if the request fails.
    func iceServers() async -> [RTCIceServer] {
        if let servers = cachedServers() { return servers }

        do {
            let response = try await fetchTURNCredentials()
            let turnServer = RTCIceServer(
                urlStrings: response.uris,
                username: response.username,
                credential: response.password
            )

            let servers = [turnServer] + Self.fallbackSTUN
            cache(servers, ttl: response.ttl)
            logCall("TURN credentials fetched (ttl: \(response.ttl)s, uris: \(response.uris))")
            return servers
        } catch {
            logCall("TURN fetch failed, using STUN only: \(error)")
            return Self.fallbackSTUN
        }
    }

    /// Invalidates the cache so the next call fetches fresh credentials.
    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    // MARK: - Private — Cache

    private struct CachedTURN {
        let servers: [RTCIceServer]
        let expiresAt: Date
    }

    private func cachedServers() -> [RTCIceServer]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached, Date() < cached.expiresAt else { return nil }
        return cached.servers
    }

    private func cache(_ servers: [RTCIceServer], ttl: Int) {
        // Refresh a bit early to avoid using expired credentials
        let margin = max(60, ttl / 10)
        let expiry = Date().addingTimeInterval(TimeInterval(ttl - margin))

        lock.lock()
        cached = CachedTURN(servers: servers, expiresAt: expiry)
        lock.unlock()
    }

    // MARK: - Private — Fetch

    private struct TURNResponse: Decodable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]
    }

    private func fetchTURNCredentials() async throws -> TURNResponse {
        guard let client = MatrixClientService.shared.client else {
            throw TURNError.noClient
        }

        let session = try client.session()
        var baseURL = session.homeserverUrl
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        let urlString = "\(baseURL)/_matrix/client/v3/voip/turnServer"

        guard let url = URL(string: urlString) else {
            throw TURNError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TURNError.httpError(code)
        }

        return try JSONDecoder().decode(TURNResponse.self, from: data)
    }

    // MARK: - Errors

    private enum TURNError: Error, CustomStringConvertible {
        case noClient
        case invalidURL
        case httpError(Int)

        var description: String {
            switch self {
            case .noClient: return "Matrix client not available"
            case .invalidURL: return "Invalid homeserver URL"
            case .httpError(let code): return "HTTP \(code)"
            }
        }
    }

    // MARK: - Fallback STUN

    private static let fallbackSTUN: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
        RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
    ]
}
