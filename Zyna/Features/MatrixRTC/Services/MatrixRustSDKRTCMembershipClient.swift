//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRTC
import MatrixRustSDK

final class MatrixRustSDKRTCMembershipClient: @unchecked Sendable {
    private let client: Client

    init(client: Client) {
        self.client = client
    }

    func loadRawMembershipEvents(roomId: String) async throws -> [MatrixRTCRawMembershipEvent] {
        let path = "/_matrix/client/v3/rooms/\(Self.percentEncodedPathComponent(roomId))/state"
        let data = try await matrixRequest(path: path)
        let events = try JSONDecoder().decode([RawStateEvent].self, from: data)

        return try events.compactMap { event in
            guard event.type == MatrixRTCRawMembershipEvent.legacyCallMemberEventType
                    || event.type == MatrixRTCRawMembershipEvent.rtcMemberEventType else {
                return nil
            }
            guard let eventId = event.eventId,
                  let sender = event.sender,
                  let timestamp = event.originServerTimestamp else {
                return nil
            }

            let contentData = try JSONEncoder().encode(event.content)
            guard let contentJSON = String(data: contentData, encoding: .utf8) else {
                throw MatrixRTCStateError.invalidUTF8
            }

            return MatrixRTCRawMembershipEvent(
                eventId: eventId,
                eventType: event.type,
                stateKey: event.stateKey,
                sender: sender,
                originServerTimestamp: timestamp,
                contentJSON: contentJSON
            )
        }
    }

    func loadActiveMemberships(
        roomId: String,
        slot: MatrixRTCSlotDescription = .matrixCallRoom,
        joinedUserIds: Set<String>? = nil,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) async throws -> [MatrixRTCCallMembership] {
        let events = try await loadRawMembershipEvents(roomId: roomId)
        return MatrixRTCCallMembershipParser.activeMemberships(
            from: events,
            for: slot,
            joinedUserIds: joinedUserIds,
            now: now
        )
    }

    private func matrixRequest(path: String) async throws -> Data {
        let session = try client.session()
        let url = try Self.matrixURL(homeserverUrl: session.homeserverUrl, percentEncodedPath: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixRTCStateError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw MatrixRTCStateError.httpStatus(http.statusCode)
        }
        return data
    }

    private static func matrixURL(homeserverUrl: String, percentEncodedPath: String) throws -> URL {
        var raw = homeserverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              components.host != nil,
              scheme == "http" || scheme == "https" else {
            throw MatrixRTCStateError.invalidURL
        }

        components.percentEncodedPath = percentEncodedPath
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MatrixRTCStateError.invalidURL
        }
        return url
    }

    private static func percentEncodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct RawStateEvent: Decodable {
    let eventId: String?
    let type: String
    let stateKey: String?
    let sender: String?
    let originServerTimestamp: Int64?
    let content: MatrixRTCJSONValue

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case type
        case stateKey = "state_key"
        case sender
        case originServerTimestamp = "origin_server_ts"
        case content
    }
}

private enum MatrixRTCStateError: Error {
    case invalidURL
    case invalidResponse
    case invalidUTF8
    case httpStatus(Int)
}
