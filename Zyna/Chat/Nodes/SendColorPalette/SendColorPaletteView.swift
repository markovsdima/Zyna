//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Arc-shaped ("fan") colour picker that springs out from the Send
/// button on long-press. Adds itself to the host window as an overlay
/// so tap-outside dismissal is trivial.
///
/// Lifecycle:
///   1. `present(inWindow:pivot:)` — adds self as subview, animates
///      circles along the arc.
///   2. `updateHighlight(forPoint:)` — call during drag to move the
///      1.3x scale to the circle under finger (or clear).
///   3. `colorAt(point:)` — hit-test; returns `UIColor` if point hits
///      a circle, nil otherwise.
///   4. `dismiss(completion:)` — reverse animation, removes from
///      superview.
final class SendColorPaletteView: UIView {

    // MARK: - Callbacks

    /// Fired when the user taps a circle while the palette is in
    /// sticky mode (presentation outlived the initial long-press).
    var onColorTapped: ((UIColor) -> Void)?

    /// Fired when the user taps anywhere else (outside any circle).
    var onDismissTapped: (() -> Void)?

    // MARK: - State

    private var circles: [PaletteCircle] = []
    private var pivotInSelf: CGPoint = .zero
    private var highlightedIndex: Int?
    private let haptic = UISelectionFeedbackGenerator()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        haptic.prepare()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Presentation

    /// Adds the palette as a window overlay and animates the circles out.
    /// - Parameters:
    ///   - window: target window (must exist).
    ///   - pivotInWindow: Send button centre in window coords.
    func present(inWindow window: UIWindow, pivotInWindow: CGPoint) {
        frame = window.bounds
        window.addSubview(self)
        pivotInSelf = pivotInWindow
        layoutCircles()
        animateIn()
    }

    func dismiss(completion: (() -> Void)? = nil) {
        UIView.animate(
            withDuration: SendColorPaletteConfig.animationDuration,
            delay: 0,
            options: [.curveEaseIn],
            animations: { [self] in
                for circle in circles {
                    circle.alpha = 0
                    circle.transform = .init(scaleX: 0.2, y: 0.2)
                        .translatedBy(
                            x: (pivotInSelf.x - circle.center.x) / 0.2,
                            y: (pivotInSelf.y - circle.center.y) / 0.2
                        )
                }
            },
            completion: { [weak self] _ in
                self?.removeFromSuperview()
                completion?()
            }
        )
    }

    // MARK: - Drag tracking

    /// Returns the colour at the given point (palette coord space), or
    /// nil. Also updates the visual highlight. Pass nil to clear.
    @discardableResult
    func updateHighlight(forPoint point: CGPoint?) -> UIColor? {
        guard let point else {
            setHighlightedIndex(nil)
            return nil
        }
        guard let index = circleIndex(at: point) else {
            setHighlightedIndex(nil)
            return nil
        }
        setHighlightedIndex(index)
        return SendColorPaletteConfig.colors[index]
    }

    /// Hit-test without mutating highlight state. Used after release.
    func colorAt(point: CGPoint) -> UIColor? {
        guard let index = circleIndex(at: point) else { return nil }
        return SendColorPaletteConfig.colors[index]
    }

    // MARK: - Private

    private func layoutCircles() {
        circles.forEach { $0.removeFromSuperview() }
        circles.removeAll()

        let count = SendColorPaletteConfig.colors.count
        let startAngle = SendColorPaletteConfig.arcStartAngle
        let endAngle = SendColorPaletteConfig.arcEndAngle
        let step = (endAngle - startAngle) / CGFloat(max(1, count - 1))
        let radius = SendColorPaletteConfig.arcRadius
        let size = SendColorPaletteConfig.circleDiameter

        for (i, color) in SendColorPaletteConfig.colors.enumerated() {
            let theta = startAngle + step * CGFloat(i)
            // UIKit y-axis is flipped — subtract the sin component.
            let cx = pivotInSelf.x + radius * cos(theta)
            let cy = pivotInSelf.y - radius * sin(theta)
            let frame = CGRect(
                x: cx - size / 2, y: cy - size / 2,
                width: size, height: size
            )
            let circle = PaletteCircle(frame: frame, color: color)
            circle.alpha = 0
            // Start compressed at pivot, then animate out.
            let dx = pivotInSelf.x - circle.center.x
            let dy = pivotInSelf.y - circle.center.y
            circle.transform = .init(scaleX: 0.2, y: 0.2)
                .translatedBy(x: dx / 0.2, y: dy / 0.2)
            addSubview(circle)
            circles.append(circle)
        }
    }

    private func animateIn() {
        for (i, circle) in circles.enumerated() {
            UIView.animate(
                withDuration: SendColorPaletteConfig.animationDuration,
                delay: Double(circles.count - 1 - i) * SendColorPaletteConfig.stagger,
                usingSpringWithDamping: 0.75,
                initialSpringVelocity: 0.6,
                options: [.curveEaseOut],
                animations: {
                    circle.alpha = 1
                    circle.transform = .identity
                },
                completion: nil
            )
        }
    }

    /// Finds the circle whose centre is closest to `point`, within
    /// half-diameter. Returns its index.
    private func circleIndex(at point: CGPoint) -> Int? {
        let maxDist = SendColorPaletteConfig.circleDiameter / 2
        var bestIndex: Int?
        var bestDist: CGFloat = .infinity
        for (i, circle) in circles.enumerated() {
            let dx = circle.center.x - point.x
            let dy = circle.center.y - point.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist < maxDist, dist < bestDist {
                bestDist = dist
                bestIndex = i
            }
        }
        return bestIndex
    }

    private func setHighlightedIndex(_ newIndex: Int?) {
        guard newIndex != highlightedIndex else { return }
        if let old = highlightedIndex, circles.indices.contains(old) {
            circles[old].setHighlighted(false)
        }
        if let new = newIndex, circles.indices.contains(new) {
            circles[new].setHighlighted(true)
            haptic.selectionChanged()
            haptic.prepare()
        }
        highlightedIndex = newIndex
    }

    // MARK: - Tap handling (sticky mode)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if let color = colorAt(point: point) {
            onColorTapped?(color)
        } else {
            onDismissTapped?()
        }
    }
}

// MARK: - PaletteCircle

/// Single colour swatch with highlight animation.
private final class PaletteCircle: UIView {

    let color: UIColor

    init(frame: CGRect, color: UIColor) {
        self.color = color
        super.init(frame: frame)
        backgroundColor = color
        layer.cornerRadius = frame.width / 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ highlighted: Bool) {
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState],
            animations: { [self] in
                let scale = highlighted ? SendColorPaletteConfig.highlightScale : 1.0
                transform = .init(scaleX: scale, y: scale)
            },
            completion: nil
        )
    }
}
