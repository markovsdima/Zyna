//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

private let logDevices = ScopedLog(.auth)

struct MatrixDevice: Decodable, Identifiable, Equatable {
    let deviceId: String
    let displayName: String?
    let lastSeenIp: String?
    let lastSeenTimestamp: Int64?

    var id: String { deviceId }

    private enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case displayName = "display_name"
        case lastSeenIp = "last_seen_ip"
        case lastSeenTimestamp = "last_seen_ts"
    }
}

enum MatrixDeviceServiceError: LocalizedError {
    case clientNotInitialized
    case invalidURL
    case invalidResponse
    case unsupportedAuthentication
    case missingAuthSession
    case invalidPassword(String?)
    case httpStatus(Int, String?)

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return String(localized: "Client is not initialized")
        case .invalidURL:
            return String(localized: "Invalid homeserver URL")
        case .invalidResponse:
            return String(localized: "Invalid server response")
        case .unsupportedAuthentication:
            return String(localized: "This server requires an authentication method Zyna does not support yet.")
        case .missingAuthSession:
            return String(localized: "The server did not return an authentication session.")
        case .invalidPassword(let message):
            return message ?? String(localized: "Current password was not accepted.")
        case .httpStatus(let status, let message):
            return message ?? String(localized: "Server returned HTTP \(status).")
        }
    }
}

final class MatrixDeviceService {
    static let shared = MatrixDeviceService()

    private let decoder = JSONDecoder()

    private init() {}

    var currentDeviceId: String? {
        guard let client = MatrixClientService.shared.client else { return nil }
        guard let session = try? client.session() else { return nil }
        return session.deviceId
    }

    func devices() async throws -> [MatrixDevice] {
        let session = try currentSession()
        let url = try makeURL(
            homeserverUrl: session.homeserverUrl,
            path: "/_matrix/client/v3/devices"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixDeviceServiceError.invalidResponse
        }

        guard http.statusCode == 200 else {
            throw parseError(statusCode: http.statusCode, data: data)
        }

        return try decoder.decode(DevicesResponse.self, from: data).devices
            .sorted { lhs, rhs in
                let lhsSeen = lhs.lastSeenTimestamp ?? 0
                let rhsSeen = rhs.lastSeenTimestamp ?? 0
                if lhsSeen == rhsSeen {
                    return lhs.deviceId.localizedCaseInsensitiveCompare(rhs.deviceId) == .orderedAscending
                }
                return lhsSeen > rhsSeen
            }
    }

    func deleteDevice(deviceId: String, currentPassword: String) async throws {
        let firstResponse = try await deleteDeviceRequest(
            deviceId: deviceId,
            auth: nil
        )

        switch firstResponse {
        case .success:
            return
        case .needsAuthentication(let uia):
            guard supportsSingleStage("m.login.password", in: uia.flows) else {
                if supportsSingleStage("m.login.dummy", in: uia.flows) {
                    let auth: [String: Any] = [
                        "type": "m.login.dummy",
                        "session": try authSession(from: uia)
                    ]
                    try await finishDeleteDevice(deviceId: deviceId, auth: auth)
                    return
                }
                throw MatrixDeviceServiceError.unsupportedAuthentication
            }

            let auth: [String: Any] = [
                "type": "m.login.password",
                "identifier": [
                    "type": "m.id.user",
                    "user": try currentSession().userId
                ],
                "password": currentPassword,
                "session": try authSession(from: uia)
            ]
            try await finishDeleteDevice(deviceId: deviceId, auth: auth)
        }
    }

    private func finishDeleteDevice(deviceId: String, auth: [String: Any]) async throws {
        let response = try await deleteDeviceRequest(
            deviceId: deviceId,
            auth: auth
        )

        switch response {
        case .success:
            return
        case .needsAuthentication(let uia):
            throw MatrixDeviceServiceError.invalidPassword(uia.error)
        }
    }

    private func deleteDeviceRequest(
        deviceId: String,
        auth: [String: Any]?
    ) async throws -> DeleteDeviceResponse {
        let session = try currentSession()
        let url = try makeURL(
            homeserverUrl: session.homeserverUrl,
            path: "/_matrix/client/v3/devices/\(Self.percentEncodedPathComponent(deviceId))",
            pathIsPercentEncoded: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: auth.map { ["auth": $0] } ?? [:])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MatrixDeviceServiceError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            logDevices("Deleted device \(deviceId)")
            return .success
        case 401:
            if let uia = try? decoder.decode(UserInteractiveAuthResponse.self, from: data) {
                return .needsAuthentication(uia)
            }
            throw parseError(statusCode: http.statusCode, data: data)
        default:
            throw parseError(statusCode: http.statusCode, data: data)
        }
    }

    private func currentSession() throws -> MatrixRustSDK.Session {
        guard let client = MatrixClientService.shared.client else {
            throw MatrixDeviceServiceError.clientNotInitialized
        }
        return try client.session()
    }

    private func makeURL(
        homeserverUrl: String,
        path: String,
        pathIsPercentEncoded: Bool = false
    ) throws -> URL {
        var raw = homeserverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              components.host != nil,
              scheme == "http" || scheme == "https" else {
            throw MatrixDeviceServiceError.invalidURL
        }

        if pathIsPercentEncoded {
            components.percentEncodedPath = path
        } else {
            components.path = path
        }
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MatrixDeviceServiceError.invalidURL
        }
        return url
    }

    private static func percentEncodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func supportsSingleStage(_ stage: String, in flows: [UserInteractiveAuthFlow]) -> Bool {
        flows.contains { $0.stages == [stage] }
    }

    private func authSession(from response: UserInteractiveAuthResponse) throws -> String {
        guard let session = response.session, !session.isEmpty else {
            throw MatrixDeviceServiceError.missingAuthSession
        }
        return session
    }

    private func parseError(statusCode: Int, data: Data) -> MatrixDeviceServiceError {
        let response = try? decoder.decode(MatrixErrorResponse.self, from: data)
        return .httpStatus(statusCode, response?.error)
    }
}

private struct DevicesResponse: Decodable {
    let devices: [MatrixDevice]
}

private struct MatrixErrorResponse: Decodable {
    let errcode: String?
    let error: String?
}

private struct UserInteractiveAuthResponse: Decodable {
    let completed: [String]?
    let flows: [UserInteractiveAuthFlow]
    let session: String?
    let errcode: String?
    let error: String?
}

private struct UserInteractiveAuthFlow: Decodable {
    let stages: [String]
}

private enum DeleteDeviceResponse {
    case success
    case needsAuthentication(UserInteractiveAuthResponse)
}
