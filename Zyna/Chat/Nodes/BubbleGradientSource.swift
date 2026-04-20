//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum BubbleGradientRole: CaseIterable, Hashable {
    case incoming
    case outgoing
    
    func colors(traits: UITraitCollection) -> [UIColor] {
        switch self {
        case .outgoing:
            return [
                UIColor(hex: 0x8AB8FF),
                UIColor(hex: 0x5C8EFA),
                UIColor(hex: 0x3954D6)
            ]
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

/// Full-chat gradient that bubble portals mirror with
/// `matchesPosition=true`. The source lives behind the table; portals
/// reveal the matching slice inside each bubble.
final class BubbleGradientSource: UIView {

    private final class PortalReference {
        weak var portal: PortalView?

        init(portal: PortalView) {
            self.portal = portal
        }
    }

    private let gradientLayer = CAGradientLayer()
    private let colorProvider: (UITraitCollection) -> [UIColor]
    private var lastBounds: CGRect = .null
    private var portalReferences: [PortalReference] = []

    init(
        colorProvider: @escaping (UITraitCollection) -> [UIColor],
        start: CGPoint = CGPoint(x: 0.0, y: 0.0),
        end: CGPoint = CGPoint(x: 1.0, y: 1.0)
    ) {
        self.colorProvider = colorProvider
        super.init(frame: .zero)
        gradientLayer.startPoint = start
        gradientLayer.endPoint = end
        gradientLayer.locations = [0.0, 0.48, 1.0]
        layer.addSublayer(gradientLayer)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        updateGradientColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func addPortal(_ portal: PortalView) {
        compactPortalReferences()
        guard !portalReferences.contains(where: { $0.portal === portal }) else { return }
        portalReferences.append(PortalReference(portal: portal))
        DispatchQueue.main.async { [weak self] in
            self?.reloadRegisteredPortals()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateGradientColors()
        DispatchQueue.main.async { [weak self] in
            self?.reloadRegisteredPortals()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        guard bounds != lastBounds else { return }
        lastBounds = bounds
        DispatchQueue.main.async { [weak self] in
            self?.reloadRegisteredPortals()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        updateGradientColors()
        DispatchQueue.main.async { [weak self] in
            self?.reloadRegisteredPortals()
        }
    }

    private func updateGradientColors() {
        gradientLayer.colors = colorProvider(traitCollection).map {
            $0.resolvedColor(with: traitCollection).cgColor
        }
    }

    private func compactPortalReferences() {
        portalReferences.removeAll { $0.portal == nil }
    }

    private func reloadRegisteredPortals() {
        compactPortalReferences()
        guard window != nil else { return }
        for reference in portalReferences {
            guard let portal = reference.portal,
                  portal.view.superview != nil else {
                continue
            }
            portal.reload()
        }
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
