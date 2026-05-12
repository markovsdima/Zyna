//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit
import UserNotifications
import MatrixRustSDK

private let logPush = ScopedLog(.push)

// MARK: - Push Service

final class PushService {

    static let shared = PushService()

    private var deviceToken: Data?

    #if DEBUG
    private static let gatewayHostPrefix = "push-dev"
    #else
    private static let gatewayHostPrefix = "push"
    #endif
    private static let gatewayPath = "/_matrix/push/v1/notify"

    private init() {}

    private static func buildURL(from homeserverUrl: String, path: String) -> URL? {
        var raw = homeserverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              components.host != nil,
              scheme == "http" || scheme == "https" else {
            return nil
        }

        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func buildGatewayURL(from homeserverUrl: String) -> URL? {
        var raw = homeserverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme,
              let host = components.host,
              scheme == "http" || scheme == "https" else {
            return nil
        }

        var labels = host.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        guard labels.count >= 2 else { return nil }
        labels[0] = gatewayHostPrefix

        components.host = labels.joined(separator: ".")
        components.path = gatewayPath
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Request Permission & Register

    /// Call after login or session restore. Requests notification permission,
    /// registers for remote notifications, and registers the pusher if a
    /// device token is already available.
    func registerIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error {
                logPush("Authorization request failed: \(error)")
                return
            }
            logPush("Notification permission granted: \(granted)")
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }

        // Token may already be cached from a previous registerForRemoteNotifications call
        if deviceToken != nil {
            Task { await registerPusher() }
        }
    }

    // MARK: - Device Token

    /// Called from AppDelegate when APNs returns a device token.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        self.deviceToken = deviceToken
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        logPush("Device token: \(hex)")

        Task {
            await registerPusher()
        }
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        logPush("Failed to register for remote notifications: \(error)")
    }

    // MARK: - Register Pusher on Homeserver

    private func registerPusher() async {
        guard let token = deviceToken else {
            logPush("No device token, skipping pusher registration")
            return
        }

        guard let client = MatrixClientService.shared.client else {
            logPush("No Matrix client, skipping pusher registration")
            return
        }

        do {
            let session = try client.session()

            guard let url = Self.buildURL(
                from: session.homeserverUrl,
                path: "/_matrix/client/v3/pushers/set"
            ) else {
                logPush("Invalid pushers URL")
                return
            }

            guard let gatewayURL = Self.buildGatewayURL(from: session.homeserverUrl) else {
                logPush("Invalid push gateway URL")
                return
            }

            let pushkey = token.map { String(format: "%02x", $0) }.joined()
            let deviceName = await UIDevice.current.name

            let body: [String: Any] = [
                "pushkey": pushkey,
                "kind": "http",
                "app_id": "com.app.zyna.Zyna",
                "app_display_name": "Zyna",
                "device_display_name": deviceName,
                "lang": "en",
                "data": [
                    "url": gatewayURL.absoluteString,
                    "format": "event_id_only"
                ]
            ]

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if statusCode == 200 {
                logPush("Pusher registered successfully")
            } else {
                logPush("Pusher registration failed: HTTP \(statusCode)")
            }
        } catch {
            logPush("Pusher registration error: \(error)")
        }
    }
}
