//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

/// Bag of Zyna-specific attributes attached to a chat message.
/// These are transport-agnostic: the same struct is used on both
/// send and receive paths, persisted in GRDB, and passed to UI.
///
/// Serialised into a single hidden `<span data-zyna="...">` element at
/// the end of `formatted_body` when sending, and extracted from the
/// raw HTML of incoming events on receive. See `ZynaHTMLCodec`.
///
/// Adding a new feature:
/// 1. Add a field here (optional — always opt-in).
/// 2. Add a case in `ZynaHTMLCodec` encode/decode.
/// 3. Bump `ZynaHTMLCodec.currentVersion` only on breaking changes.
struct ZynaMessageAttributes: Equatable {

    /// Custom bubble color. Rendered as the message bubble background in Zyna.
    /// Other Matrix clients ignore this (it lives in the hidden span).
    var color: UIColor?

    /// Checklist items (future feature).
    var checklist: [ChecklistItem]?

    var callSignal: CallSignalData?

    /// Display name of the original sender when forwarded.
    var forwardedFrom: String?

    /// Presentation-only metadata for photo groups. Foreign clients
    /// ignore it; Zyna can use it to visually stitch adjacent media.
    var mediaGroup: MediaGroupInfo?

    init(
        color: UIColor? = nil,
        checklist: [ChecklistItem]? = nil,
        callSignal: CallSignalData? = nil,
        forwardedFrom: String? = nil,
        mediaGroup: MediaGroupInfo? = nil
    ) {
        self.color = color
        self.checklist = checklist
        self.callSignal = callSignal
        self.forwardedFrom = forwardedFrom
        self.mediaGroup = mediaGroup
    }

    var isEmpty: Bool {
        color == nil
            && (checklist == nil || checklist?.isEmpty == true)
            && callSignal == nil
            && forwardedFrom == nil
            && mediaGroup == nil
    }

    static func == (lhs: ZynaMessageAttributes, rhs: ZynaMessageAttributes) -> Bool {
        lhs.color?.hexString == rhs.color?.hexString
            && lhs.checklist == rhs.checklist
            && lhs.callSignal == rhs.callSignal
            && lhs.forwardedFrom == rhs.forwardedFrom
            && lhs.mediaGroup == rhs.mediaGroup
    }
}

// MARK: - Nested types

struct ChecklistItem: Codable, Equatable {
    var text: String
    var checked: Bool
}

struct CallSignalData: Codable, Equatable {
    /// Matrix event type, e.g. "m.call.answer", "m.call.candidates",
    /// "m.call.hangup".
    var type: String
    /// JSON-encoded event content (CallAnswerContent,
    /// CallCandidatesContent, etc.). Opaque to the codec —
    /// CallSignalingService decodes the concrete type.
    var payload: String
}

struct MediaGroupInfo: Codable, Equatable {
    var id: String
    /// Zero-based item position inside the original client-side order.
    var index: Int
    /// Intended group size. Treated as a hint; the actual visible set
    /// may be smaller after failures, redactions, or edits.
    var total: Int
    var captionMode: CaptionMode
    var captionPlacement: CaptionPlacement
    var layoutOverride: MediaGroupLayoutOverride?

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case total
        case captionMode
        case captionPlacement
        case layoutOverride
    }

    init(
        id: String,
        index: Int,
        total: Int,
        captionMode: CaptionMode,
        captionPlacement: CaptionPlacement,
        layoutOverride: MediaGroupLayoutOverride? = nil
    ) {
        self.id = id
        self.index = index
        self.total = total
        self.captionMode = captionMode
        self.captionPlacement = captionPlacement
        self.layoutOverride = layoutOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        index = try container.decode(Int.self, forKey: .index)
        total = try container.decode(Int.self, forKey: .total)
        captionMode = try container.decode(CaptionMode.self, forKey: .captionMode)
        captionPlacement = try container.decodeIfPresent(CaptionPlacement.self, forKey: .captionPlacement) ?? .bottom
        layoutOverride = try container.decodeIfPresent(MediaGroupLayoutOverride.self, forKey: .layoutOverride)
    }
}

struct MediaGroupLayoutOverride: Codable, Equatable {
    /// Position of the main divider, normalized into 0...1000.
    /// 2 items: vertical split between left and right.
    /// 3 items: vertical split between the large left tile and the
    /// stacked right column.
    var primarySplitPermille: Int
    /// Position of the secondary divider, normalized into 0...1000.
    /// Only used for 3-item layouts, where it controls the split
    /// between the top-right and bottom-right tiles.
    var secondarySplitPermille: Int?
}

enum CaptionMode: String, Codable, Equatable {
    case replicated
}

enum CaptionPlacement: String, Codable, Equatable {
    case top
    case bottom
}

// MARK: - UIColor hex helper

extension UIColor {

    /// Returns the color as an uppercase "#RRGGBB" string.
    /// Alpha is ignored.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((max(0, min(1, r)) * 255).rounded())
        let gi = Int((max(0, min(1, g)) * 255).rounded())
        let bi = Int((max(0, min(1, b)) * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    /// Parses "#RRGGBB" or "RRGGBB". Returns nil on invalid input.
    static func fromHexString(_ hex: String) -> UIColor? {
        var s = hex.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
