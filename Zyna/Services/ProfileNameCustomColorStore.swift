//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

struct ProfileNameCustomColor: Codable, Equatable {
    let id: String
    var name: String
    var hexString: String
}

final class ProfileNameCustomColorStore {
    static let shared = ProfileNameCustomColorStore()

    private let defaults: UserDefaults
    private let colorsKey = "com.zyna.profileNameCustomColors.v1"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func colors() -> [ProfileNameCustomColor] {
        guard let data = defaults.data(forKey: colorsKey),
              let colors = try? JSONDecoder().decode([ProfileNameCustomColor].self, from: data) else {
            return []
        }
        return colors
    }

    @discardableResult
    func saveColor(name: String, hexString: String) -> ProfileNameCustomColor {
        let color = ProfileNameCustomColor(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            hexString: hexString
        )
        var colors = colors()
        colors.removeAll { $0.hexString == hexString }
        colors.insert(color, at: 0)
        persist(colors)
        return color
    }

    func replaceColors(_ colors: [ProfileNameCustomColor]) {
        persist(colors)
    }

    func deleteColor(id: String) {
        var colors = colors()
        colors.removeAll { $0.id == id }
        persist(colors)
    }

    func renameColor(id: String, name: String) {
        var colors = colors()
        guard let index = colors.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        colors[index].name = trimmed
        persist(colors)
    }

    private func persist(_ colors: [ProfileNameCustomColor]) {
        guard let data = try? JSONEncoder().encode(Array(colors.prefix(48))) else { return }
        defaults.set(data, forKey: colorsKey)
    }
}
