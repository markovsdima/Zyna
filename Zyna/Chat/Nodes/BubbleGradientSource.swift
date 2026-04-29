//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

class PortalSourceView: UIView {

    private final class PortalReference {
        weak var portal: PortalView?

        init(portal: PortalView) {
            self.portal = portal
        }
    }

    private var portalReferences: [PortalReference] = []

    func addPortal(_ portal: PortalView) {
        compactPortalReferences()
        guard !portalReferences.contains(where: { $0.portal === portal }) else {
            portal.sourceView = self
            return
        }
        portalReferences.append(PortalReference(portal: portal))
        portal.sourceView = self
    }

    func removePortal(_ portal: PortalView) {
        compactPortalReferences()
        portalReferences.removeAll { $0.portal === portal }
        if portal.sourceView === self {
            portal.sourceView = nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestPortalReload()
    }

    func requestPortalReload() {
        compactPortalReferences()
        guard window != nil else { return }
        for reference in portalReferences {
            guard let portal = reference.portal else { continue }
            portal.sourceView = self
        }
    }

    private func compactPortalReferences() {
        portalReferences.removeAll { $0.portal == nil }
    }
}

private final class BubbleGradientCanvasView: UIView {

    private let gradientLayer = CAGradientLayer()
    private let colorProvider: (UITraitCollection) -> [UIColor]

    init(
        colorProvider: @escaping (UITraitCollection) -> [UIColor],
        start: CGPoint,
        end: CGPoint
    ) {
        self.colorProvider = colorProvider
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        gradientLayer.startPoint = start
        gradientLayer.endPoint = end
        layer.addSublayer(gradientLayer)
        updateGradientColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        updateGradientColors()
    }

    private func updateGradientColors() {
        let colors = colorProvider(traitCollection)
        gradientLayer.colors = colors.map {
            $0.resolvedColor(with: traitCollection).cgColor
        }
        gradientLayer.locations = BubbleGradientStops.layerLocations(for: colors.count)
    }
}

/// Shared per-role source host. The portal mirrors this host, not the
/// gradient view directly. That keeps source/content concerns separate
/// from portal delivery and matches Telegram's `PortalSourceView` model.
final class BubbleGradientSource: PortalSourceView {

    private let gradientView: BubbleGradientCanvasView

    init(
        colorProvider: @escaping (UITraitCollection) -> [UIColor],
        start: CGPoint = CGPoint(x: 0.0, y: 0.0),
        end: CGPoint = CGPoint(x: 1.0, y: 1.0)
    ) {
        self.gradientView = BubbleGradientCanvasView(
            colorProvider: colorProvider,
            start: start,
            end: end
        )
        super.init(frame: .zero)
        alpha = 0.0
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(gradientView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientView.frame = bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        requestPortalReload()
    }
}

private struct BubbleRGBA {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

private extension UIColor {
    func resolvedRGBA(with traits: UITraitCollection) -> BubbleRGBA {
        let resolved = resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return BubbleRGBA(red: red, green: green, blue: blue, alpha: alpha)
        }
        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &alpha) {
            return BubbleRGBA(red: white, green: white, blue: white, alpha: alpha)
        }
        return BubbleRGBA(red: 0, green: 0, blue: 0, alpha: 1)
    }
}

enum BubbleGradientRole: CaseIterable, Hashable {
    case incoming
    case outgoing

    func colors(traits: UITraitCollection, outgoingTheme: ChatBubbleTheme) -> [UIColor] {
        switch self {
        case .outgoing:
            return outgoingTheme.outgoingGradientColors
        case .incoming:
            let surface = AppColor.bubbleBackgroundIncoming.resolvedColor(with: traits)
            let isDark = traits.userInterfaceStyle == .dark
            return [
                Self.mix(surface, with: UIColor.white, ratio: isDark ? 0.10 : 0.18, traits: traits),
                surface,
                Self.mix(surface, with: UIColor.black, ratio: isDark ? 0.18 : 0.08, traits: traits)
            ]
        }
    }

    private static func mix(_ color: UIColor, with other: UIColor, ratio: CGFloat, traits: UITraitCollection) -> UIColor {
        let clampedRatio = max(0, min(1, ratio))
        let base = color.resolvedRGBA(with: traits)
        let target = other.resolvedRGBA(with: traits)
        let inverse = 1 - clampedRatio
        return UIColor(
            red: base.red * inverse + target.red * clampedRatio,
            green: base.green * inverse + target.green * clampedRatio,
            blue: base.blue * inverse + target.blue * clampedRatio,
            alpha: base.alpha * inverse + target.alpha * clampedRatio
        )
    }
}
