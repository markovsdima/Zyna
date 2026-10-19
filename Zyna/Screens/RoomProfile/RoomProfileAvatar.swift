// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit
import MatrixRustSDK

enum RoomProfileAvatarGeometry {
    static let diameter: CGFloat = 88
    static let topInset: CGFloat = 12

    static func expansionHeight(width: CGFloat) -> CGFloat {
        max(0, width - diameter - topInset)
    }

    static func frame(width: CGFloat, top: CGFloat, progress: CGFloat, collapse: CGFloat) -> CGRect {
        let side = diameter + (width - diameter) * progress
        return CGRect(x: (width - side) / 2,
            y: top + topInset * (1 - progress) - collapse, width: side, height: side)
    }
}

/// A drag's snap decision is separate from its continuously rendered position.
/// Hysteresis prevents threshold chatter; each target change produces a tick.
struct RoomProfileAvatarDrag {
    static let scrollSpeed: CGFloat = 1.5
    let initiallyExpanded: Bool
    private(set) var wantsExpanded: Bool
    private var translation: CGFloat
    private var previousProgress: CGFloat
    private var directionalTravel: CGFloat = 0

    init(progress: CGFloat, translation: CGFloat = 0) {
        initiallyExpanded = progress >= 0.5
        wantsExpanded = initiallyExpanded
        self.translation = translation
        previousProgress = progress
    }

    /// Read physical movement independently of the content offset we adjust.
    /// Otherwise each correction could feed into the next scroll callback.
    mutating func scrollDelta(translation: CGFloat) -> CGFloat {
        defer { self.translation = translation }
        return self.translation - translation
    }

    mutating func rebaseTranslation(_ translation: CGFloat) {
        self.translation = translation
    }

    mutating func update(collapse: CGFloat, expansion: CGFloat) -> Bool {
        guard expansion > 0 else { return false }
        let previousTarget = wantsExpanded
        let progress = max(0, min(1, 1 - collapse / expansion))
        let movement = (progress - previousProgress) * expansion
        previousProgress = progress
        if abs(movement) > 0.001 {
            directionalTravel = movement * directionalTravel > 0 ? directionalTravel + movement : movement
        }
        let distance = initiallyExpanded ? collapse : expansion - collapse
        let threshold = min(96, expansion * 0.45)
        let reverting = wantsExpanded != initiallyExpanded
        if distance >= threshold { wantsExpanded = !initiallyExpanded }
        else if reverting && distance < max(0, threshold - 18) { wantsExpanded = initiallyExpanded }
        return wantsExpanded != previousTarget
    }

    /// UIKit reports content velocity in points/ms: negative opens the photo.
    /// Require both speed and deliberate travel in the final direction, and
    /// count only movement inside the photo segment, not the preceding list.
    mutating func finish(velocity: CGFloat) -> Bool {
        let previousTarget = wantsExpanded
        let minimumTravel = 18 * Self.scrollSpeed
        if velocity <= -0.5, directionalTravel >= minimumTravel {
            wantsExpanded = true
        } else if velocity >= 0.5, directionalTravel <= -minimumTravel {
            wantsExpanded = false
        }
        return wantsExpanded != previousTarget
    }
}

/// One image-backed layer, independent of Texture's measured header layout.
/// Touches pass through to the page's existing scroll view. The controller
/// handles taps, while VoiceOver activates this element directly.
final class RoomProfileAvatarView: UIView {
    private static let expandLabel = String(localized: "Expand photo", table: "RoomProfile")
    private static let collapseLabel = String(localized: "Collapse photo", table: "RoomProfile")
    var onActivate: (() -> Void)?
    var image: UIImage? { didSet { layer.contents = image?.cgImage } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "profile.avatar"
        accessibilityTraits = [.button, .image]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func accessibilityActivate() -> Bool {
        guard isAccessibilityElement else { return false }
        onActivate?()
        return true
    }

    func update(width: CGFloat, top: CGFloat, progress: CGFloat, collapse: CGFloat, canExpand: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = RoomProfileAvatarGeometry.frame(width: width, top: top, progress: progress, collapse: collapse)
        // Finish squaring the corners halfway through the expansion.
        layer.cornerRadius = RoomProfileAvatarGeometry.diameter / 2 * max(0, 1 - progress * 2)
        CATransaction.commit()
        isAccessibilityElement = canExpand && frame.maxY > top
        let label = progress >= 0.5 ? Self.collapseLabel : Self.expandLabel
        if accessibilityLabel != label { accessibilityLabel = label }
    }
}

/// The cache's bubble preparation bounds decoding and normalizes orientation
/// off-main, even when a homeserver returns the original instead of a thumbnail.
enum RoomProfileAvatarImageLoader {
    static func load(_ mxc: String, _ pixels: Int) async -> UIImage? {
        guard let source = try? MediaSource.fromUrl(url: mxc) else { return nil }
        return await MediaCache.shared.loadBubbleImage(source: source,
            maxPixelWidth: pixels, maxPixelHeight: pixels, knownAspectRatio: 1)?.image
    }
}
