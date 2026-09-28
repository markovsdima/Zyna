//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

enum IgnoredUsersServiceError: Error {
    case noClient
}

/// Matrix `m.ignored_user_list`, stored as account data so it follows the
/// user across devices. Homeservers suppress ignored users' non-state events.
final class IgnoredUsersService {

    static let shared = IgnoredUsersService()

    private init() {}

    private var client: Client? { MatrixClientService.shared.client }

    func ignoredUserIds() async throws -> [String] {
        guard let client else { throw IgnoredUsersServiceError.noClient }
        return try await client.ignoredUsers()
    }

    /// The caller owns the handle; releasing it ends the subscription.
    func observeIgnoredUsers(
        _ onChange: @escaping @Sendable ([String]) -> Void
    ) -> TaskHandle? {
        client?.subscribeToIgnoredUsers(
            listener: IgnoredUsersCallbackListener(callback: onChange)
        )
    }

    func ignore(userId: String) async throws {
        guard let client else { throw IgnoredUsersServiceError.noClient }
        try await client.ignoreUser(userId: userId)
    }

    func unignore(userId: String) async throws {
        guard let client else { throw IgnoredUsersServiceError.noClient }
        try await client.unignoreUser(userId: userId)
    }
}

private final class IgnoredUsersCallbackListener: IgnoredUsersListener {

    private let callback: @Sendable ([String]) -> Void

    init(callback: @escaping @Sendable ([String]) -> Void) {
        self.callback = callback
    }

    func call(ignoredUserIds: [String]) {
        callback(ignoredUserIds)
    }
}
