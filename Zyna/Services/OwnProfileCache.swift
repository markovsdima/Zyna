//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

final class OwnProfileCache {
    static let shared = OwnProfileCache()

    private let defaults: UserDefaults
    private let displayNamesKey = "com.zyna.ownProfile.displayNames.v1"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func displayName(userId: String) -> String? {
        guard !userId.isEmpty else { return nil }
        return displayNames()[userId]
    }

    func setDisplayName(_ displayName: String?, userId: String) {
        guard !userId.isEmpty else { return }
        var names = displayNames()
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            names[userId] = trimmed
        } else {
            names.removeValue(forKey: userId)
        }
        defaults.set(names, forKey: displayNamesKey)
    }

    private func displayNames() -> [String: String] {
        defaults.dictionary(forKey: displayNamesKey) as? [String: String] ?? [:]
    }
}
