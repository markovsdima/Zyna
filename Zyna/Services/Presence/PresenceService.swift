//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import CryptoKit

private let logPresence = ScopedLog(.presence)

struct UserPresence {
    let online: Bool
    let lastSeen: Date?
}

final class PresenceService {

    static let shared = PresenceService()

    // TODO: Move to config / environment before production
    private let baseURL = "http://localhost:8080"
    private let hmacSecret = "my-test-secret"

    private var heartbeatTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    // MARK: - Heartbeat

    func startHeartbeatLoop(userId: String) {
        stopHeartbeatLoop()
        logPresence("Heartbeat loop started for \(userId)")
        heartbeatTask = Task {
            while !Task.isCancelled {
                await sendHeartbeat(userId: userId)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        logPresence("Heartbeat loop stopped")
    }

    private func sendHeartbeat(userId: String) async {
        let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userId
        guard let url = URL(string: "\(baseURL)/presence/\(encoded)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(computeApiKey(), forHTTPHeaderField: "X-API-Key")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            logPresence("Heartbeat → \(code)")
        } catch {
            logPresence("Heartbeat error: \(error)")
        }
    }

    // MARK: - Batch Status

    func batchStatus(userIds: [String]) async -> [String: UserPresence] {
        logPresence("batchStatus requested for \(userIds.count) users: \(userIds)")
        guard !userIds.isEmpty, let url = URL(string: "\(baseURL)/presence/status") else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(computeApiKey(), forHTTPHeaderField: "X-API-Key")
        request.httpBody = try? JSONEncoder().encode(["user_ids": userIds])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            logPresence("batchStatus response → \(code)")
            let decoded = try Self.isoDecoder.decode(PresenceBatchResponse.self, from: data)
            let result = decoded.users.mapValues { UserPresence(online: $0.online, lastSeen: $0.lastSeen) }
            logPresence("batchStatus parsed: \(result.map { "\($0.key)=\($0.value.online)" }.joined(separator: ", "))")
            return result
        } catch {
            logPresence("batchStatus error: \(error)")
            return [:]
        }
    }

    // MARK: - API Key

    private func computeApiKey() -> String {
        let dateString = Self.dateFormatter.string(from: Date())
        let key = SymmetricKey(data: Data(hmacSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(dateString.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Response Models

private struct PresenceBatchResponse: Decodable {
    let users: [String: PresenceUserDTO]
}

private struct PresenceUserDTO: Decodable {
    let online: Bool
    let lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case online
        case lastSeen = "last_seen"
    }
}
