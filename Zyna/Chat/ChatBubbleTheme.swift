//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

struct ChatBubbleTheme: Equatable {
    let id: String
    let title: String
    let outgoingGradientColors: [UIColor]
    let startPoint: CGPoint
    let endPoint: CGPoint

    init(
        id: String,
        title: String,
        outgoingGradientColors: [UIColor],
        startPoint: CGPoint = CGPoint(x: 0.5, y: 0.0),
        endPoint: CGPoint = CGPoint(x: 0.5, y: 1.0)
    ) {
        self.id = id
        self.title = title
        self.outgoingGradientColors = outgoingGradientColors
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    static let zynaBlue = ChatBubbleTheme(
        id: "zynaBlue",
        title: String(localized: "Zyna Blue"),
        outgoingGradientColors: [
            UIColor(hex: 0x8AB8FF),
            UIColor(hex: 0x5C8EFA),
            UIColor(hex: 0x3954D6)
        ]
    )

    static let auroraLime = ChatBubbleTheme(
        id: "auroraLime",
        title: String(localized: "Aurora Lime"),
        outgoingGradientColors: [
            UIColor(hex: 0xB6D94A),
            UIColor(hex: 0x2DBA70),
            UIColor(hex: 0x057A67)
        ]
    )

    static let forest = ChatBubbleTheme(
        id: "forest",
        title: String(localized: "Forest"),
        outgoingGradientColors: [
            UIColor(hex: 0x72B878),
            UIColor(hex: 0x2FA66A),
            UIColor(hex: 0x075C4A)
        ]
    )

    static let violetBlue = ChatBubbleTheme(
        id: "violetBlue",
        title: String(localized: "Violet Blue"),
        outgoingGradientColors: [
            UIColor(hex: 0xB05CFF),
            UIColor(hex: 0x6B4DFF),
            UIColor(hex: 0x1268FF)
        ]
    )

    static let emberRose = ChatBubbleTheme(
        id: "emberRose",
        title: String(localized: "Ember Rose"),
        outgoingGradientColors: [
            UIColor(hex: 0xFF9AAE),
            UIColor(hex: 0xE6507A),
            UIColor(hex: 0x7B3FF2)
        ]
    )

    static let lagoonTeal = ChatBubbleTheme(
        id: "lagoonTeal",
        title: String(localized: "Lagoon Teal"),
        outgoingGradientColors: [
            UIColor(hex: 0x5DE2E7),
            UIColor(hex: 0x20B7BC),
            UIColor(hex: 0x1768D8)
        ]
    )

    static let solarCoral = ChatBubbleTheme(
        id: "solarCoral",
        title: String(localized: "Solar Coral"),
        outgoingGradientColors: [
            UIColor(hex: 0xFFB15C),
            UIColor(hex: 0xFF6B61),
            UIColor(hex: 0xC43BE8)
        ]
    )

    static let mango = ChatBubbleTheme(
        id: "mango",
        title: String(localized: "Mango"),
        outgoingGradientColors: [
            UIColor(hex: 0xFFD36E),
            UIColor(hex: 0xFF9D3D),
            UIColor(hex: 0xEF4E5D)
        ]
    )

    static let graphiteCyan = ChatBubbleTheme(
        id: "graphiteCyan",
        title: String(localized: "Graphite Cyan"),
        outgoingGradientColors: [
            UIColor(hex: 0x556070),
            UIColor(hex: 0x2563EB),
            UIColor(hex: 0x06B6D4)
        ]
    )

    static let rubyPlum = ChatBubbleTheme(
        id: "rubyPlum",
        title: String(localized: "Ruby Plum"),
        outgoingGradientColors: [
            UIColor(hex: 0xFF5A7D),
            UIColor(hex: 0xC72E7E),
            UIColor(hex: 0x5B32D6)
        ]
    )

    static let deepOcean = ChatBubbleTheme(
        id: "deepOcean",
        title: String(localized: "Deep Ocean"),
        outgoingGradientColors: [
            UIColor(hex: 0x7DD3FC),
            UIColor(hex: 0x0EA5A4),
            UIColor(hex: 0x1E3A8A)
        ],
        startPoint: CGPoint(x: 0.0, y: 0.0),
        endPoint: CGPoint(x: 1.0, y: 1.0)
    )

    static let northernNight = ChatBubbleTheme(
        id: "northernNight",
        title: String(localized: "Northern Night"),
        outgoingGradientColors: [
            UIColor(hex: 0x22D3EE),
            UIColor(hex: 0x6366F1),
            UIColor(hex: 0x312E81)
        ],
        startPoint: CGPoint(x: 0.0, y: 0.0),
        endPoint: CGPoint(x: 1.0, y: 1.0)
    )

    static let irisMint = ChatBubbleTheme(
        id: "irisMint",
        title: String(localized: "Iris Mint"),
        outgoingGradientColors: [
            UIColor(hex: 0xA78BFA),
            UIColor(hex: 0x2DD4BF),
            UIColor(hex: 0x0F766E)
        ],
        startPoint: CGPoint(x: 1.0, y: 0.0),
        endPoint: CGPoint(x: 0.0, y: 1.0)
    )

    static let midnight = ChatBubbleTheme(
        id: "midnight",
        title: String(localized: "Midnight"),
        outgoingGradientColors: [
            UIColor(hex: 0x94A3B8),
            UIColor(hex: 0x475569),
            UIColor(hex: 0x0F172A)
        ]
    )

    static let all: [ChatBubbleTheme] = [
        .zynaBlue,
        .auroraLime,
        .forest,
        .violetBlue,
        .emberRose,
        .lagoonTeal,
        .solarCoral,
        .mango,
        .graphiteCyan,
        .rubyPlum,
        .deepOcean,
        .northernNight,
        .irisMint,
        .midnight
    ]

    static let fallback = zynaBlue

    static func theme(id: String) -> ChatBubbleTheme? {
        return all.first { $0.id == id }
    }

    static func == (lhs: ChatBubbleTheme, rhs: ChatBubbleTheme) -> Bool {
        lhs.id == rhs.id
    }
}

extension ChatBubbleTheme {
    var actionAccentColor: UIColor {
        guard !outgoingGradientColors.isEmpty else { return AppColor.accent }
        if outgoingGradientColors.count >= 3 {
            return outgoingGradientColors[1]
        }
        return outgoingGradientColors[outgoingGradientColors.count - 1]
    }
}

final class ChatBubbleThemeStore {
    static let shared = ChatBubbleThemeStore()
    static let didChangeNotification = Notification.Name("ChatBubbleThemeStore.didChange")

    private enum DefaultsKey {
        static let selectedThemeId = "chatBubbleTheme.selectedThemeId"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedTheme: ChatBubbleTheme {
        selectedThemeId.flatMap(ChatBubbleTheme.theme(id:)) ?? .fallback
    }

    var selectedThemeId: String? {
        defaults.string(forKey: DefaultsKey.selectedThemeId)
    }

    func setSelectedTheme(id: String) {
        guard ChatBubbleTheme.theme(id: id) != nil else { return }
        let oldId = selectedThemeId
        defaults.set(id, forKey: DefaultsKey.selectedThemeId)
        if oldId != id {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

enum BubbleGradientStops {
    static func layerLocations(for colorCount: Int) -> [NSNumber]? {
        cgLocations(for: colorCount)?.map { NSNumber(value: Double($0)) }
    }

    static func cgLocations(for colorCount: Int) -> [CGFloat]? {
        guard colorCount > 1 else { return nil }
        if colorCount == 3 {
            return [0.0, 0.48, 1.0]
        }
        return (0 ..< colorCount).map { index in
            CGFloat(index) / CGFloat(colorCount - 1)
        }
    }
}
