//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Network

private let log = ScopedLog(.presence)

struct UserPresence {
    let online: Bool
    let lastSeen: Date?
}

/// WebSocket client for the standalone presence server that replaces
/// Synapse's built-in presence (too resource-heavy).
/// Protocol: JWT auth via HTTP, then a persistent WebSocket for
/// subscribe/push updates and keepalive pings.
/// - SeeAlso: [zyna-presence](https://github.com/markovsdima/zyna-presence)
final class PresenceService {

    static let shared = PresenceService()

    private let presencePort = 8080
    private let devPassword: String? = nil // nil = production (Bearer token), non-nil = dev mode
    private let pingInterval: TimeInterval = 10
    private let connectionTimeout: TimeInterval = 15

    // MARK: - Callbacks (called on background queue)

    var onStatuses: (([String: UserPresence]) -> Void)?
    var onPresenceChange: ((String, UserPresence) -> Void)?
    var onDisconnect: (() -> Void)?

    // MARK: - Private State

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.zyna.presence.ws", qos: .utility)
    private var pingTask: Task<Void, Never>?
    private var currentBaseURL: String?
    private var currentAccessToken: String?
    private var currentUserId: String?

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {}

    /// Derives presence server base URL from homeserver URL by replacing the port.
    /// e.g. "https://example.com:443/" → "https://example.com:8080"
    private func buildBaseURL(from homeserverUrl: String) -> String? {
        guard var components = URLComponents(string: homeserverUrl) else { return nil }
        components.port = presencePort
        components.path = ""
        return components.string
    }

    // MARK: - Public API

    func connect(homeserverUrl: String, accessToken: String, userId: String) async throws {
        disconnect()

        guard let base = buildBaseURL(from: homeserverUrl) else {
            throw PresenceError.invalidURL
        }

        currentBaseURL = base
        currentAccessToken = accessToken
        currentUserId = userId

        let jwt = try await fetchJWT(accessToken: accessToken, userId: userId)
        try await establishWebSocket()
        try await sendJSON(AuthMessage(token: jwt))
        startPingLoop()
        startReceiving()

        log("Connected")
    }

    func disconnect() {
        pingTask?.cancel()
        pingTask = nil
        connection?.cancel()
        connection = nil
    }

    func subscribe(userIds: [String]) {
        guard connection?.state == .ready, !userIds.isEmpty else { return }
        Task { try? await sendJSON(SubscribeMessage(userIds: userIds)) }
    }

    // MARK: - JWT

    private func fetchJWT(accessToken: String, userId: String) async throws -> String {
        guard let baseURL = currentBaseURL,
              let url = URL(string: "\(baseURL)/presence/auth") else {
            throw PresenceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let devPassword {
            request.setValue(devPassword, forHTTPHeaderField: "Authorization")
            request.setValue(userId, forHTTPHeaderField: "X-User-ID")
        } else {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PresenceError.authFailed
        }

        let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
        log("JWT obtained, expires in \(decoded.expiresIn)s")
        return decoded.token
    }

    // MARK: - WebSocket Connection

    private func establishWebSocket() async throws {
        guard let baseURL = currentBaseURL else { throw PresenceError.invalidURL }
        let wsURL = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
            + "/presence/ws"

        guard let url = URL(string: wsURL) else {
            throw PresenceError.invalidURL
        }

        let useTLS = url.scheme == "wss"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            wsOptions.maximumMessageSize = 256 * 1024

            let parameters: NWParameters
            if useTLS {
                parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
            } else {
                parameters = NWParameters.tcp
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

            let connection = NWConnection(to: .url(url), using: parameters)
            self.connection = connection

            var resumed = false

            let timeout = DispatchWorkItem {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(throwing: PresenceError.timeout)
            }
            self.queue.asyncAfter(deadline: .now() + self.connectionTimeout, execute: timeout)

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    timeout.cancel()
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()

                case .failed(let error):
                    timeout.cancel()
                    self?.connection = nil
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: error)

                case .cancelled:
                    timeout.cancel()
                    self?.connection = nil
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(throwing: PresenceError.cancelled)

                case .waiting(let error):
                    log("Waiting: \(error)")

                default:
                    break
                }
            }

            connection.start(queue: self.queue)
        }
    }

    // MARK: - Send

    private func sendJSON<T: Encodable>(_ message: T) async throws {
        guard let connection, connection.state == .ready else {
            throw PresenceError.notConnected
        }
        let data = try JSONEncoder().encode(message)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "presenceMessage",
                metadata: [metadata]
            )
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Receive

    private func startReceiving() {
        guard let connection, connection.state == .ready else { return }
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let error {
                self.handleConnectionLost(error: error)
                return
            }

            if let data, !data.isEmpty,
               let context,
               let metadata = context.protocolMetadata(
                   definition: NWProtocolWebSocket.definition
               ) as? NWProtocolWebSocket.Metadata {

                switch metadata.opcode {
                case .text, .binary:
                    self.parseMessage(data)
                case .close:
                    self.handleConnectionLost(error: nil)
                    return
                default:
                    break
                }
            }

            guard connection.state == .ready else { return }
            self.receiveNext(on: connection)
        }
    }

    // MARK: - Parse

    private func parseMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "statuses":
            guard let users = json["users"] as? [[String: Any]] else { return }
            var result: [String: UserPresence] = [:]
            for entry in users {
                guard let userId = entry["user_id"] as? String else { continue }
                result[userId] = Self.parsePresence(entry)
            }
            log("Statuses snapshot: \(result.count) users")
            onStatuses?(result)

        case "presence":
            guard let userId = json["user_id"] as? String else { return }
            let presence = Self.parsePresence(json)
            log("\(userId) → \(presence.online ? "online" : "offline")")
            onPresenceChange?(userId, presence)

        case "token_expired":
            log("Token expired, refreshing")
            refreshToken()

        case "error":
            log("Server error: \(json["message"] as? String ?? "unknown")")

        default:
            break
        }
    }

    private static func parsePresence(_ dict: [String: Any]) -> UserPresence {
        let online = dict["online"] as? Bool ?? false
        let lastSeen: Date?
        if let str = dict["last_seen"] as? String {
            lastSeen = isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
        } else {
            lastSeen = nil
        }
        return UserPresence(online: online, lastSeen: lastSeen)
    }

    // MARK: - Token Refresh

    private func refreshToken() {
        guard let accessToken = currentAccessToken, let userId = currentUserId else { return }
        Task {
            do {
                let jwt = try await fetchJWT(accessToken: accessToken, userId: userId)
                try await sendJSON(AuthMessage(token: jwt))
                log("Token refreshed")
            } catch {
                log("Token refresh failed: \(error)")
                disconnect()
                onDisconnect?()
            }
        }
    }

    // MARK: - Connection Lost

    private func handleConnectionLost(error: Error?) {
        if let nwError = error as? NWError,
           case .posix(let code) = nwError, code == .ECANCELED {
            return
        }
        log("Connection lost\(error.map { ": \($0)" } ?? "")")
        connection = nil
        pingTask?.cancel()
        pingTask = nil
        onDisconnect?()
    }

    // MARK: - Ping

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { [weak self, pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard !Task.isCancelled else { return }
                try? await self?.sendJSON(PingMessage())
            }
        }
    }
}

// MARK: - Protocol Messages

private struct AuthMessage: Encodable {
    let type = "auth"
    let token: String
}

private struct SubscribeMessage: Encodable {
    let type = "subscribe"
    let userIds: [String]
    enum CodingKeys: String, CodingKey {
        case type
        case userIds = "user_ids"
    }
}

private struct PingMessage: Encodable {
    let type = "ping"
}

private struct AuthResponse: Decodable {
    let token: String
    let expiresIn: Int
    let userId: String
    enum CodingKeys: String, CodingKey {
        case token
        case expiresIn = "expires_in"
        case userId = "user_id"
    }
}

enum PresenceError: LocalizedError {
    case invalidURL
    case authFailed
    case timeout
    case cancelled
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid presence server URL"
        case .authFailed: "Presence auth failed"
        case .timeout: "Connection timed out"
        case .cancelled: "Connection cancelled"
        case .notConnected: "Not connected"
        }
    }
}
