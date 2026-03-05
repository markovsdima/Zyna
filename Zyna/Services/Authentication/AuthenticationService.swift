//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK
import KeychainAccess

// MARK: - Authentication Errors

enum AuthenticationError: LocalizedError {
    case clientNotInitialized
    case loginFailed(String)
    case invalidCredentials
    case networkError
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "Client not initialized"
        case .loginFailed(let message):
            return "Login failed: \(message)"
        case .invalidCredentials:
            return "Invalid username or password"
        case .networkError:
            return "Network connection error"
        case .sessionNotFound:
            return "No saved session found"
        }
    }
}

// MARK: - Session Data Model

struct SessionData: Codable {
    let accessToken: String
    let refreshToken: String?
    let userId: String
    let deviceId: String
    let homeserverUrl: String
    let oidcData: String?
}

private let keychainLog = ScopedLog(.keychain)

// MARK: - Session Delegate

final class DefaultSessionDelegate: ClientSessionDelegate {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let keychain = Keychain(service: "com.zyna.matrix.session")
        .accessibility(.whenUnlockedThisDeviceOnly)

    func retrieveSessionFromKeychain(userId: String) throws -> MatrixRustSDK.Session {
        guard let sessionDataString = try keychain.get(userId),
              let data = sessionDataString.data(using: .utf8) else {
            throw AuthenticationError.sessionNotFound
        }

        let decoded = try decoder.decode(SessionData.self, from: data)

        return MatrixRustSDK.Session(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            userId: decoded.userId,
            deviceId: decoded.deviceId,
            homeserverUrl: decoded.homeserverUrl,
            oidcData: decoded.oidcData,
            slidingSyncVersion: .native
        )
    }

    func saveSessionInKeychain(session: MatrixRustSDK.Session) {
        let sessionData = SessionData(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oidcData: session.oidcData
        )

        do {
            let data = try encoder.encode(sessionData)
            let dataString = String(data: data, encoding: .utf8) ?? ""
            try keychain.set(dataString, key: session.userId)
            keychainLog("Session saved for user: \(session.userId)")
        } catch {
            keychainLog("Failed to save session: \(error)")
        }
    }

    func clearSession(userId: String) {
        do {
            try keychain.remove(userId)
            keychainLog("Session cleared for user: \(userId)")
        } catch {
            keychainLog("Failed to clear session: \(error)")
        }
    }
}
