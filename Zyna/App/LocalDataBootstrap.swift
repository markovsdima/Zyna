//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Shared by scene startup and headless session restoration (incoming calls).
/// Waiting callers never run Keychain, cleanup, or database opening on main.
final class LocalDataBootstrap {
    static let shared = LocalDataBootstrap()
    private let task: Task<Bool, Never>

    private init() {
        task = Task.detached(priority: .userInitiated) {
            Self.prepareInstallation()
            // Resolve legacy/shared markers before choosing the account DB.
            let userId = MatrixClientService.shared.storedUserIdForLocalStartup
            do {
                try await DatabaseService.shared.activate(userId: userId)
            } catch {
                // Preserve the existing startup failure policy. Never present
                // the messenger with an unavailable or partially migrated DB.
                fatalError("Unable to open encrypted app database: \(error)")
            }
            return userId != nil
        }
    }

    @discardableResult
    func ready() async -> Bool { await task.value }

    private static func prepareInstallation() {
        let defaults = UserDefaults.standard
        let sentinel = "com.zyna.installation.initialized"
        guard defaults.object(forKey: sentinel) == nil else { return }
        if defaults.string(forKey: ZynaSecurityConfig.matrixLastUserIdKey) == nil {
            MatrixClientService.resetPersistedSessionStateAfterFreshInstall()
        }
        defaults.set(true, forKey: sentinel)
        defaults.synchronize()
    }
}
