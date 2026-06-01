//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK
@preconcurrency import KeychainAccess

// MARK: - Authentication Errors

enum AuthenticationError: LocalizedError {
    case clientNotInitialized
    case loginFailed(String)
    case invalidCredentials
    case networkError
    case sessionNotFound
    case invalidOAuthURL
    case registrationNotSupported

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
        case .invalidOAuthURL:
            return "Server returned an invalid authentication URL"
        case .registrationNotSupported:
            return "This server does not support registration"
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
    let oauthData: String?
}

private let logKeychain = ScopedLog(.keychain)

// MARK: - Session Delegate

final class DefaultSessionDelegate: ClientSessionDelegate {
    private static let sessionKeychainService = "com.zyna.matrix.session"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let sharedKeychain = ZynaSecurityConfig.sharedKeychain(service: DefaultSessionDelegate.sessionKeychainService)
    private let legacyKeychain = ZynaSecurityConfig.legacyKeychain(service: DefaultSessionDelegate.sessionKeychainService)

    func retrieveSessionFromKeychain(userId: String) throws -> MatrixRustSDK.Session {
        guard let sessionDataString = try sessionDataString(for: userId),
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
            oauthData: decoded.oauthData,
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
            oauthData: session.oauthData
        )

        do {
            let data = try encoder.encode(sessionData)
            let dataString = String(data: data, encoding: .utf8) ?? ""
            var didSaveSharedSession = false
            do {
                try sharedKeychain.set(dataString, key: session.userId)
                didSaveSharedSession = true
            } catch {
                logKeychain("Failed to save session in shared keychain, falling back to legacy for user \(session.userId): \(error)")
                try legacyKeychain.set(dataString, key: session.userId)
            }
            if didSaveSharedSession {
                try? legacyKeychain.remove(session.userId)
            }
            logKeychain("Session saved for user: \(session.userId)")
        } catch {
            logKeychain("Failed to save session: \(error)")
        }
    }

    func clearSession(userId: String) {
        let sharedResult = Result { try sharedKeychain.remove(userId) }
        let legacyResult = Result { try legacyKeychain.remove(userId) }

        switch (sharedResult, legacyResult) {
        case (.success, .success), (.success, .failure), (.failure, .success):
            logKeychain("Session cleared for user: \(userId)")
        case (.failure(let sharedError), .failure(let legacyError)):
            logKeychain("Failed to clear session: shared=\(sharedError) legacy=\(legacyError)")
        }
    }

    func clearAllSessions() {
        let sharedResult = Result { try sharedKeychain.removeAll() }
        let legacyResult = Result { try legacyKeychain.removeAll() }

        switch (sharedResult, legacyResult) {
        case (.success, .success), (.success, .failure), (.failure, .success):
            logKeychain("All sessions cleared")
        case (.failure(let sharedError), .failure(let legacyError)):
            logKeychain("Failed to clear all sessions: shared=\(sharedError) legacy=\(legacyError)")
        }
    }

    private func sessionDataString(for userId: String) throws -> String? {
        do {
            if let shared = try sharedKeychain.get(userId) {
                return shared
            }
        } catch {
            logKeychain("Failed to read shared session for user \(userId): \(error)")
        }

        do {
            guard let legacy = try legacyKeychain.get(userId) else {
                return nil
            }
            do {
                try sharedKeychain.set(legacy, key: userId)
                logKeychain("Migrated session to shared keychain for user: \(userId)")
            } catch {
                logKeychain("Failed to migrate session to shared keychain for user \(userId): \(error)")
            }
            return legacy
        } catch {
            logKeychain("Failed to read legacy session for user \(userId): \(error)")
            throw error
        }
    }
}
