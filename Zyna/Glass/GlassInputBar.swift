//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AsyncDisplayKit

/// Glass input bar with 3 shapes: attach (circle), text field (rounded rect), mic (circle).
/// Optional 4th shape: scroll-to-live button (metaball with mic).
/// Lives in the main window, content placed above glass renderer via GlassService.
/// Tracks keyboard position and triggers glass capture on changes.
final class GlassInputBar: UIView {

    // MARK: - Public

    let inputNode = ChatInputNode()

    /// The view to capture as glass background (e.g. the table/scroll view).
    weak var sourceView: UIView? {
        didSet { anchor.sourceView = sourceView }
    }

    /// Background color the glass should sample where `sourceView`
    /// has no cells. Defaults to the chat background; override only
    /// if hosting glass over a non-chat surface.
    var backdropClearColor: UIColor = AppColor.chatBackground {
        didSet { anchor.backdropClearColor = backdropClearColor }
    }

    /// Show/hide the scroll-to-live button. Animates from/to mic button.
    var scrollButtonVisible: Bool = false {
        didSet {
            guard oldValue != scrollButtonVisible else { return }
            animateScrollButton(visible: scrollButtonVisible)
        }
    }

    /// Called when scroll-to-live button is tapped.
    var onScrollToLive: (() -> Void)?

    // MARK: - Private

    private let anchor = GlassAnchor()
    private let contentView = ScrollButtonContentView()
    private var keyboardHeight: CGFloat = 0

    // Chrome bars state
    private var currentBarHeights: [Float] = []
    private var barsActive: Bool = false

    // Scroll button animation state
    private var scrollButtonProgress: CGFloat = 0  // 0 = hidden at mic, 1 = fully deployed
    private var scrollButtonTarget: CGFloat = 0
    private var scrollButtonVelocity: CGFloat = 0
    private var scrollButtonDisplayLink: CADisplayLink?
    private var scrollButtonLastTime: CFTimeInterval = 0

    // Scroll button views (positioned in contentView, clipping disabled)
    private let scrollButtonIcon = UIImageView()
    private let scrollButtonTap = UIButton(type: .custom)

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        anchor.cornerRadius = 24
        anchor.extendsCaptureToScreenBottom = false
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        addSubview(anchor)

        contentView.backgroundColor = .clear
        contentView.addSubview(inputNode.view)

        // Remove default background — glass is our background
        inputNode.backgroundColor = .clear
        inputNode.view.backgroundColor = .clear

        anchor.barProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildBarData(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
        }

        inputNode.onWaveformUpdate = { [weak self] waveform in
            self?.updateBarHeights(waveform)
        }

        // Scroll button icon + tap target (in contentView, above glass)
        scrollButtonIcon.image = AppIcon.chevronDown.rendered(size: 24, color: .gray)
        scrollButtonIcon.contentMode = .center
        scrollButtonIcon.alpha = 0
        contentView.addSubview(scrollButtonIcon)

        scrollButtonTap.alpha = 0
        scrollButtonTap.addTarget(self, action: #selector(scrollButtonTapped), for: .touchUpInside)
        contentView.addSubview(scrollButtonTap)

        // Allow scroll button to render above contentView bounds
        contentView.clipsToBounds = false

        observeKeyboard()
        observeInputSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            GlassService.shared.attachContent(contentView, for: anchor)
        } else {
            contentView.removeFromSuperview()
        }
    }

    // MARK: - Layout

    /// Call from ChatViewController.viewDidLayoutSubviews()
    private let barInsetClosed: CGFloat = 6
    private let barInsetOpen: CGFloat = 0

    func updateLayout(in parentView: UIView) {
        let safeBottom = parentView.safeAreaInsets.bottom

        let insetH = keyboardHeight > 0 ? barInsetOpen : barInsetClosed
        let fullWidth = parentView.bounds.width
        let barWidth = fullWidth - insetH * 2

        // Measure input node height
        let fittedSize = inputNode.layoutThatFits(ASSizeRange(
            min: CGSize(width: barWidth, height: 0),
            max: CGSize(width: barWidth, height: .greatestFiniteMagnitude)
        )).size

        let barY: CGFloat
        if keyboardHeight > 0 {
            barY = parentView.bounds.height - fittedSize.height - keyboardHeight - safeBottom - 4
        } else {
            barY = parentView.bounds.height - fittedSize.height - safeBottom * 0.5
        }

        frame = CGRect(x: insetH, y: barY, width: barWidth, height: fittedSize.height)
        anchor.frame = bounds

        inputNode.frame = CGRect(x: 0, y: 0, width: barWidth, height: fittedSize.height)
    }

    /// Returns how much space the input bar + keyboard covers at the bottom.
    var coveredHeight: CGFloat {
        guard let superview else { return 0 }
        let safeBottom = superview.safeAreaInsets.bottom
        if keyboardHeight > 0 {
            return bounds.height + keyboardHeight + safeBottom + 4
        } else {
            return bounds.height + safeBottom * 0.5
        }
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt,
              let superview else { return }

        let screenH = UIScreen.main.bounds.height
        let newKeyboardH = max(0, screenH - endFrame.origin.y)

        // Subtract safe area — we handle it ourselves
        let safeBottom = superview.safeAreaInsets.bottom
        keyboardHeight = max(0, newKeyboardH - safeBottom)

        // Enable liquid pool for keyboard animation splash
        anchor.extendsCaptureToScreenBottom = true

        GlassService.shared.captureFor(duration: duration + 0.1)

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16),
            animations: {
                self.updateLayout(in: superview)
                // Notify ChatViewController to update table insets
                self.superview?.setNeedsLayout()
                self.superview?.layoutIfNeeded()
            }
        )
    }

    // MARK: - Multi-shape

    private func buildShapes(glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat) -> GlassRenderer.ShapeParams {
        var p = GlassRenderer.ShapeParams()
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return p }

        // Layout constants from ChatInputNode.normalLayout
        let hPad: CGFloat = 14   // horizontal padding
        let vPad: CGFloat = 6    // vertical padding
        let btnSize: CGFloat = 48
        let spacing: CGFloat = 8 // between button and text field
        let cornerR: CGFloat = 24

        let contentY = glassFrame.origin.y + vPad
        let contentH = glassFrame.height - vPad * 2

        // Attach button (circle, bottom-aligned)
        let attachCX = glassFrame.origin.x + hPad + btnSize / 2
        let attachCY = contentY + contentH - btnSize / 2
        let attachR = btnSize / 2

        // Mic/Send button (circle, bottom-aligned)
        let micCX = glassFrame.maxX - hPad - btnSize / 2
        let micCY = attachCY
        let micR = btnSize / 2

        // Text field (rounded rect, between buttons)
        let textX = glassFrame.origin.x + hPad + btnSize + spacing
        let textW = glassFrame.width - hPad * 2 - btnSize * 2 - spacing * 2
        let textY = contentY
        let textH = contentH

        // Shape 0: text field (rounded rect)
        p.shape0 = SIMD4<Float>(
            Float((textX - captureFrame.origin.x) / cw),
            Float((textY - captureFrame.origin.y) / ch),
            Float(textW / cw),
            Float(textH / ch)
        )
        p.shape0cornerR = Float(cornerR * scale) / Float(ch * scale)

        // Shape 1: attach (circle) — center + radius normalized by capture height
        p.shape1 = SIMD4<Float>(
            Float((attachCX - captureFrame.origin.x) / cw),
            Float((attachCY - captureFrame.origin.y) / ch),
            Float(attachR / ch),
            0
        )

        // Shape 3: scroll-to-live button + volume-preserving mic inflation
        let scrollR: CGFloat = micR  // same size as mic button
        let scrollTargetCX = micCX
        let scrollTargetCY = glassFrame.origin.y - 12 - scrollR

        var effectiveMicR = micR

        if scrollButtonProgress > 0.001 {
            let t = scrollButtonProgress
            let scrollCX = micCX + (scrollTargetCX - micCX) * t
            let scrollCY = micCY + (scrollTargetCY - micCY) * t
            // Radius: full size for most of travel, shrink only near mic (t < 0.25)
            let radiusFactor = min(1, t * 4)
            let scrollCurrentR = scrollR * radiusFactor

            // Volume-preserving mic inflation:
            // When scroll overlaps mic, mic absorbs its area → swells.
            // mergeFactor: 1 = fully overlapping, 0 = separated.
            let dx = scrollCX - micCX
            let dy = scrollCY - micCY
            let dist = sqrt(dx * dx + dy * dy)
            let sumR = micR + scrollCurrentR
            let mergeFactor = max(0, min(1, 1 - dist / max(sumR, 0.001)))

            // mic area + scroll area × mergeFactor → inflated radius
            let micArea = micR * micR
            let scrollArea = scrollCurrentR * scrollCurrentR
            effectiveMicR = sqrt(micArea + scrollArea * mergeFactor)

            p.shape3 = SIMD4<Float>(
                Float((scrollCX - captureFrame.origin.x) / cw),
                Float((scrollCY - captureFrame.origin.y) / ch),
                Float(scrollCurrentR / ch),
                0
            )
            p.scrollButtonVisible = 1

            // Position icon + tap area in contentView coords (contentView.frame = glassFrame)
            let iconCX = scrollCX - glassFrame.origin.x
            let iconCY = scrollCY - glassFrame.origin.y
            let iconSize = scrollCurrentR * 2
            scrollButtonIcon.frame = CGRect(
                x: iconCX - iconSize / 2,
                y: iconCY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            scrollButtonIcon.alpha = radiusFactor

            scrollButtonTap.frame = scrollButtonIcon.frame.insetBy(dx: -8, dy: -8)
            scrollButtonTap.alpha = t > 0.3 ? 1 : 0
        } else {
            p.scrollButtonVisible = 0
            scrollButtonIcon.alpha = 0
            scrollButtonTap.alpha = 0
        }

        // Shape 2: mic (circle) — inflated when absorbing scroll button volume
        p.shape2 = SIMD4<Float>(
            Float((micCX - captureFrame.origin.x) / cw),
            Float((micCY - captureFrame.origin.y) / ch),
            Float(effectiveMicR / ch),
            0
        )

        p.shapeCount = 3

        return p
    }

    // MARK: - Input size changes

    private func observeInputSize() {
        inputNode.onSizeChanged = { [weak self] in
            guard let self, let superview = self.superview else { return }
            self.updateLayout(in: superview)
            superview.setNeedsLayout()
            // Sustain capture while layout settles (reply show/hide, text grow/shrink)
            GlassService.shared.captureFor(duration: 0.5)
        }
    }

    // MARK: - Chrome Bars

    private func updateBarHeights(_ waveform: [Float]) {
        barsActive = !waveform.isEmpty
        anchor.hasBars = barsActive

        if waveform.isEmpty {
            currentBarHeights = []
            return
        }

        // Resample waveform tail to 16 bars
        let barCount = 16
        let tail = Array(waveform.suffix(barCount))
        var heights = [Float](repeating: 0, count: barCount)
        for i in 0..<min(tail.count, barCount) {
            heights[i] = tail[i]
        }
        currentBarHeights = heights

        GlassService.shared.setNeedsCapture()
    }

    // MARK: - Scroll Button

    @objc private func scrollButtonTapped() {
        onScrollToLive?()
    }

    private func animateScrollButton(visible: Bool) {
        scrollButtonTarget = visible ? 1 : 0
        // Expand capture frame immediately on show; clear only when settled at 0
        if visible {
            anchor.hasScrollButton = true
        }

        if scrollButtonDisplayLink == nil {
            scrollButtonLastTime = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(scrollButtonTick))
            link.add(to: .main, forMode: .common)
            scrollButtonDisplayLink = link
        }
    }

    @objc private func scrollButtonTick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(now - scrollButtonLastTime)
        scrollButtonLastTime = now

        // Spring dynamics: slow enough to appreciate the metaball + volume transfer
        let stiffness: CGFloat = 50
        let damping: CGFloat = 10
        let displacement = scrollButtonProgress - scrollButtonTarget
        let springForce = -stiffness * displacement
        let dampingForce = -damping * scrollButtonVelocity
        scrollButtonVelocity += (springForce + dampingForce) * dt
        scrollButtonProgress += scrollButtonVelocity * dt

        // Clamp and check convergence
        scrollButtonProgress = max(0, min(1, scrollButtonProgress))

        let settled = abs(scrollButtonProgress - scrollButtonTarget) < 0.001
                   && abs(scrollButtonVelocity) < 0.01
        if settled {
            scrollButtonProgress = scrollButtonTarget
            scrollButtonVelocity = 0
            scrollButtonDisplayLink?.invalidate()
            scrollButtonDisplayLink = nil

            if scrollButtonTarget == 0 {
                anchor.hasScrollButton = false
            }
            // Sustain capture to ensure glass redraws with new capture frame
            GlassService.shared.captureFor(duration: 0.15)
            return
        }

        GlassService.shared.setNeedsCapture()
    }

    private func buildBarData(
        glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat
    ) -> GlassRenderer.BarData? {
        guard barsActive, !currentBarHeights.isEmpty else { return nil }

        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return nil }

        let maxBarHeight: CGFloat = 80

        // Text field horizontal bounds (same as shape0)
        let hPad: CGFloat = 14
        let btnSize: CGFloat = 48
        let spacing: CGFloat = 8
        let textX = glassFrame.origin.x + hPad + btnSize + spacing
        let textW = glassFrame.width - hPad * 2 - btnSize * 2 - spacing * 2

        // Zone: above glass frame top edge
        let zoneBottom = glassFrame.origin.y
        let zoneTop = zoneBottom - maxBarHeight

        return GlassRenderer.BarData(
            heights: currentBarHeights,
            count: min(currentBarHeights.count, 16),
            zone: SIMD4<Float>(
                Float((textX - captureFrame.origin.x) / cw),
                Float((zoneTop - captureFrame.origin.y) / ch),
                Float(textW / cw),
                Float(maxBarHeight / ch)
            )
        )
    }
}

// MARK: - Content view with extended hit testing

/// Extends hit testing to subviews outside bounds (scroll button above the input bar).
private final class ScrollButtonContentView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Check subviews even if point is outside our bounds
        for sub in subviews.reversed() {
            guard sub.alpha > 0, !sub.isHidden, sub.isUserInteractionEnabled else { continue }
            let local = sub.convert(point, from: self)
            if let hit = sub.hitTest(local, with: event) {
                return hit
            }
        }
        return super.hitTest(point, with: event)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        // Accept touches that hit subviews outside bounds
        for sub in subviews {
            guard sub.alpha > 0, !sub.isHidden, sub.isUserInteractionEnabled else { continue }
            let local = sub.convert(point, from: self)
            if sub.point(inside: local, with: event) { return true }
        }
        return false
    }
}
