//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AsyncDisplayKit
import Metal

/// Glass input bar with 3 shapes: attach (circle), text field (rounded rect), mic (circle).
/// Optional 4th shape: scroll-to-live button (metaball with mic).
/// Tracks keyboard position and triggers glass capture on changes.
final class GlassInputBar: ASDisplayNode {

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

    /// Called each animation frame with the scroll button's current
    /// icon frame, icon alpha, tap frame, tap alpha — in this bar's
    /// parent view coordinate space. The owner (ChatViewController)
    /// positions the actual UIViews at its level.
    /// Driven by the spring animation in `scrollButtonTick`.
    var onScrollButtonLayoutChanged: ((CGRect, CGFloat, CGRect, CGFloat) -> Void)?

    /// Mirrors the shader's smoothed material state so icons outside this
    /// node (scroll-to-live chevron) can stay legible too.
    var onAdaptiveMaterialChanged: ((GlassAdaptiveMaterial) -> Void)?

    // MARK: - Private

    private let anchor = GlassAnchor()
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

    // Metal-rendered right action glyph (mic ↔ send)
    private var rightGlyphVisible: Bool = true
    private var rightGlyphProgress: CGFloat = 0  // 0 = mic, 1 = send
    private var rightGlyphTarget: CGFloat = 0
    private var rightGlyphVelocity: CGFloat = 0
    private var rightGlyphDisplayLink: CADisplayLink?
    private var rightGlyphLastTime: CFTimeInterval = 0
    private var rightGlyphSendColor: UIColor = AppColor.accent
    private let previewCloseButton = UIButton(type: .custom)
    // 1 = normal speed. Raise to 8 when inspecting the mic/send morph.
    private let rightGlyphAnimationSlowdown: CGFloat = 1
    private var rightGlyphAnimationTimeScale: CGFloat {
        max(1, rightGlyphAnimationSlowdown)
    }

    // MARK: - Init

    override init() {
        super.init()
        anchor.debugName = "input"
        inputNode.backgroundColor = .clear
    }

    deinit {
        scrollButtonDisplayLink?.invalidate()
        rightGlyphDisplayLink?.invalidate()
    }

    // MARK: - didLoad

    override func didLoad() {
        super.didLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

        // Glass UIView parts — below subnode views
        anchor.cornerRadius = 24
        anchor.extendsCaptureToScreenBottom = false
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        anchor.barProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildBarData(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
        }
        anchor.glyphProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildGlyphData(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
        }
        anchor.previewProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildPreviewData(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
        }
        anchor.onAdaptiveMaterialChanged = { [weak self] material in
            self?.inputNode.applyGlassAdaptiveMaterial(material)
            self?.onAdaptiveMaterialChanged?(material)
        }
        view.addSubview(anchor)
        anchor.accessibilityElementsHidden = true
        inputNode.applyGlassAdaptiveMaterial(anchor.adaptiveMaterial)

        // Input node as subnode (already ASDisplayNode)
        addSubnode(inputNode)
        inputNode.view.backgroundColor = .clear
        inputNode.setMetalActionGlyphsEnabled(true)
        inputNode.onRightGlyphStateChanged = { [weak self] state in
            self?.applyRightGlyphState(state)
        }
        inputNode.onPreviewRenderStateChanged = { [weak self] in
            self?.handlePreviewRenderStateChanged()
        }
        applyRightGlyphState(inputNode.rightGlyphState, animated: false)
        handlePreviewRenderStateChanged()

        previewCloseButton.backgroundColor = .clear
        previewCloseButton.isHidden = true
        previewCloseButton.isAccessibilityElement = true
        previewCloseButton.accessibilityElementsHidden = true
        previewCloseButton.accessibilityLabel = inputNode.previewCloseAccessibilityLabel
        previewCloseButton.accessibilityHint = String(localized: "Dismisses this preview")
        previewCloseButton.accessibilityIdentifier = "chat.input.preview.close"
        previewCloseButton.accessibilityTraits = .button
        previewCloseButton.addTarget(self, action: #selector(previewCloseTapped), for: .touchUpInside)
        view.addSubview(previewCloseButton)
        view.bringSubviewToFront(previewCloseButton)

        view.sendSubviewToBack(anchor)

        inputNode.onWaveformUpdate = { [weak self] waveform in
            self?.updateBarHeights(waveform)
        }

        observeKeyboard()
        observeInputSize()
    }

    var accessibilityElementsInOrder: [UIView] {
        guard isNodeLoaded, !isHidden else { return [] }

        var elements: [UIView] = []
        let previewState = inputNode.previewRenderState
        if previewState.mode != .none,
           previewState.progress > 0.001,
           !previewCloseButton.isHidden {
            elements.append(previewCloseButton)
        }

        if inputNode.attachButtonNode.isNodeLoaded {
            elements.append(inputNode.attachButtonNode.view)
        }
        if inputNode.textInputNode.isNodeLoaded {
            elements.append(inputNode.textInputNode.view)
        }

        let rightButton = inputNode.rightGlyphState.showsSend
            ? inputNode.sendButtonNode
            : inputNode.micButtonNode
        if rightButton.isNodeLoaded {
            elements.append(rightButton.view)
        }
        return elements
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityElementsInOrder }
        set { }
    }

    // MARK: - Layout

    private let barInsetClosed: CGFloat = 6
    private let barInsetOpen: CGFloat = 0
    private let previewTextRenderer = GlassInputPreviewTextRenderer()

    func updateLayout(in parentView: UIView) {
        let safeBottom = parentView.safeAreaInsets.bottom
        anchor.hasPreview = inputNode.previewRenderState.isActive

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
        anchor.renderHostContainerView = parentView
        inputNode.frame = CGRect(x: 0, y: 0, width: barWidth, height: fittedSize.height)

        // Bar position changed — scroll button position must follow
        emitScrollButtonLayout()
        updatePreviewCloseHitTarget()
    }

    /// Returns how much space the input bar + keyboard covers at the bottom.
    var coveredHeight: CGFloat {
        guard let parentView = view.superview else { return 0 }
        let safeBottom = parentView.safeAreaInsets.bottom
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
              let parentView = view.superview else { return }

        let screenH = UIScreen.main.bounds.height
        let newKeyboardH = max(0, screenH - endFrame.origin.y)

        // Subtract safe area — we handle it ourselves
        let safeBottom = parentView.safeAreaInsets.bottom
        keyboardHeight = max(0, newKeyboardH - safeBottom)

        // Enable liquid pool for keyboard animation splash
        anchor.extendsCaptureToScreenBottom = true

        GlassService.shared.captureFor(duration: duration + 0.1)

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16),
            animations: {
                self.updateLayout(in: parentView)
                // Notify ChatViewController to update table insets
                parentView.setNeedsLayout()
                parentView.layoutIfNeeded()
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
        let previewState = inputNode.previewRenderState
        let previewProgress = min(1, max(0, previewState.progress))

        // Attach button (circle, bottom-aligned)
        let attachCX = glassFrame.origin.x + hPad + btnSize / 2
        let attachCY = contentY + contentH - btnSize / 2
        let attachR = btnSize / 2

        // Mic/Send button (circle, bottom-aligned)
        let micCX = glassFrame.maxX - hPad - btnSize / 2
        let micCY = attachCY
        let micR = btnSize / 2

        // Text field glass. When the reply/forward/edit preview is active,
        // ChatInputNode reserves space above the field; the glass follows the
        // full column instead of adding a second island above it.
        let textX = glassFrame.origin.x + hPad + btnSize + spacing
        let textW = glassFrame.width - hPad * 2 - btnSize * 2 - spacing * 2
        let textY = contentY
        let textH = max(btnSize, contentH)

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
            // When scroll overlaps mic, mic absorbs its area -> swells.
            // mergeFactor: 1 = fully overlapping, 0 = separated.
            let dx = scrollCX - micCX
            let dy = scrollCY - micCY
            let dist = sqrt(dx * dx + dy * dy)
            let sumR = micR + scrollCurrentR
            let mergeFactor = max(0, min(1, 1 - dist / max(sumR, 0.001)))

            // mic area + scroll area x mergeFactor -> inflated radius
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
        } else {
            p.scrollButtonVisible = 0
        }

        // Shape 2: mic (circle) — inflated when absorbing scroll button volume
        p.shape2 = SIMD4<Float>(
            Float((micCX - captureFrame.origin.x) / cw),
            Float((micCY - captureFrame.origin.y) / ch),
            Float(effectiveMicR / ch),
            0
        )

        p.shapeCount = 3

        if previewState.isActive, previewProgress > 0.001 {
            let cardFrame = previewCardFrame(
                glassFrame: glassFrame,
                contentY: contentY,
                textX: textX,
                textW: textW
            )
            p.previewRect = normalizedRect(cardFrame, in: captureFrame)
            p.previewCornerR = Float(20 * scale) / Float(ch * scale)
            p.previewProgress = Float(previewProgress)
        }

        return p
    }

    private func handlePreviewRenderStateChanged() {
        anchor.hasPreview = inputNode.previewRenderState.isActive
        updatePreviewCloseHitTarget()
        GlassService.shared.setNeedsCapture()
    }

    @objc private func previewCloseTapped() {
        inputNode.cancelActivePreview()
    }

    private func updatePreviewCloseHitTarget() {
        let state = inputNode.previewRenderState
        guard state.isActive, state.progress > 0.001, bounds.width > 0, bounds.height > 0 else {
            previewCloseButton.isHidden = true
            previewCloseButton.isUserInteractionEnabled = false
            previewCloseButton.accessibilityElementsHidden = true
            previewCloseButton.accessibilityValue = nil
            previewCloseButton.frame = .zero
            return
        }

        let hPad: CGFloat = 14
        let vPad: CGFloat = 6
        let btnSize: CGFloat = 48
        let spacing: CGFloat = 8
        let contentY = bounds.origin.y + vPad
        let textX = bounds.origin.x + hPad + btnSize + spacing
        let textW = bounds.width - hPad * 2 - btnSize * 2 - spacing * 2
        let cardFrame = previewCardFrame(
            glassFrame: bounds,
            contentY: contentY,
            textX: textX,
            textW: textW
        )
        let visualSize: CGFloat = 30
        let visualFrame = CGRect(
            x: cardFrame.maxX - 8 - visualSize,
            y: cardFrame.minY + floor((cardFrame.height - visualSize) * 0.5),
            width: visualSize,
            height: visualSize
        )

        previewCloseButton.frame = visualFrame.insetBy(dx: -10, dy: -10).integral
        let acceptsTouches = state.mode != .none && state.progress > 0.001
        previewCloseButton.isHidden = false
        previewCloseButton.isUserInteractionEnabled = acceptsTouches
        previewCloseButton.accessibilityElementsHidden = !acceptsTouches
        previewCloseButton.accessibilityLabel = inputNode.previewCloseAccessibilityLabel
        previewCloseButton.accessibilityValue = inputNode.previewAccessibilityValue
        previewCloseButton.accessibilityHint = String(localized: "Dismisses this preview")
        view.bringSubviewToFront(previewCloseButton)
    }

    // MARK: - Input size changes

    private func observeInputSize() {
        inputNode.onSizeChanged = { [weak self] in
            guard let self, let parentView = self.view.superview else { return }
            let oldFrame = self.frame
            self.updateLayout(in: parentView)
            parentView.setNeedsLayout()
            let frameChanged = abs(self.frame.height - oldFrame.height) > 0.5
                || abs(self.frame.origin.y - oldFrame.origin.y) > 0.5
                || abs(self.frame.width - oldFrame.width) > 0.5
            if frameChanged {
                // Sustain capture while layout settles (reply show/hide, text grow/shrink).
                GlassService.shared.captureFor(duration: 0.5)
            } else {
                GlassService.shared.setNeedsRender()
            }
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

    // MARK: - Right Glyph Morph

    private func applyRightGlyphState(
        _ state: ChatInputNode.RightGlyphState,
        animated: Bool = true
    ) {
        rightGlyphVisible = state.visible
        rightGlyphSendColor = state.sendColor

        let target: CGFloat = state.showsSend ? 1 : 0
        guard animated else {
            rightGlyphDisplayLink?.invalidate()
            rightGlyphDisplayLink = nil
            rightGlyphTarget = target
            rightGlyphProgress = target
            rightGlyphVelocity = 0
            GlassService.shared.setNeedsRender()
            return
        }

        rightGlyphTarget = target
        startRightGlyphDisplayLink()
        GlassService.shared.renderFor(duration: 0.55 * TimeInterval(rightGlyphAnimationTimeScale))
        GlassService.shared.setNeedsRender()
    }

    private func startRightGlyphDisplayLink() {
        guard rightGlyphDisplayLink == nil else { return }
        rightGlyphLastTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(rightGlyphTick))
        link.add(to: .main, forMode: .common)
        rightGlyphDisplayLink = link
    }

    @objc private func rightGlyphTick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(now - rightGlyphLastTime) / rightGlyphAnimationTimeScale
        rightGlyphLastTime = now

        let stiffness: CGFloat = 135
        let damping: CGFloat = 20
        let displacement = rightGlyphProgress - rightGlyphTarget
        let springForce = -stiffness * displacement
        let dampingForce = -damping * rightGlyphVelocity
        rightGlyphVelocity += (springForce + dampingForce) * dt
        rightGlyphProgress += rightGlyphVelocity * dt
        rightGlyphProgress = max(0, min(1, rightGlyphProgress))

        let settled = abs(rightGlyphProgress - rightGlyphTarget) < 0.001
                   && abs(rightGlyphVelocity) < 0.01
        if settled {
            rightGlyphProgress = rightGlyphTarget
            rightGlyphVelocity = 0
            rightGlyphDisplayLink?.invalidate()
            rightGlyphDisplayLink = nil
        }

        GlassService.shared.setNeedsRender()
    }

    private func buildGlyphData(
        glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat
    ) -> GlassRenderer.GlyphData? {
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return nil }

        let hPad: CGFloat = 14
        let vPad: CGFloat = 6
        let btnSize: CGFloat = 48

        let contentY = glassFrame.origin.y + vPad
        let contentH = glassFrame.height - vPad * 2
        let centerY = contentY + contentH - btnSize / 2
        let attachCenterX = glassFrame.origin.x + hPad + btnSize / 2
        let rightCenterX = glassFrame.maxX - hPad - btnSize / 2

        let sendColor = resolvedRGBA(rightGlyphSendColor)
        let activity = min(1, Float(abs(rightGlyphVelocity) * 0.035)
            + Float(abs(rightGlyphTarget - rightGlyphProgress) * 1.4))

        var items: [GlassRenderer.GlyphItem] = []
        if rightGlyphVisible {
            items.append(
                staticGlyph(
                    source: .attach,
                    center: CGPoint(x: attachCenterX, y: centerY),
                    iconSize: 25,
                    effectSize: 33,
                    captureFrame: captureFrame
                )
            )
            items.append(
                GlassRenderer.GlyphItem(
                    rect: normalizedRect(centeredAt: CGPoint(x: rightCenterX, y: centerY), size: 27, in: captureFrame),
                    effectRect: normalizedRect(centeredAt: CGPoint(x: rightCenterX, y: centerY), size: 35, in: captureFrame),
                    source0: .mic,
                    source1: .send,
                    progress: Float(rightGlyphProgress),
                    opacity: 1,
                    activity: activity,
                    sendColor: sendColor
                )
            )
        }

        if scrollButtonProgress > 0.001 {
            let scrollRadius = btnSize / 2
            let scrollTargetY = glassFrame.origin.y - 12 - scrollRadius
            let t = scrollButtonProgress
            let radiusFactor = min(1, t * 4)
            let scrollCenter = CGPoint(
                x: rightCenterX,
                y: centerY + (scrollTargetY - centerY) * t
            )
            let iconSize = max(1, 27 * radiusFactor)
            let effectSize = max(1, 35 * radiusFactor)
            items.append(
                staticGlyph(
                    source: .chevronDown,
                    center: scrollCenter,
                    iconSize: iconSize,
                    effectSize: effectSize,
                    opacity: Float(radiusFactor),
                    captureFrame: captureFrame
                )
            )
        }

        guard !items.isEmpty else { return nil }
        return GlassRenderer.GlyphData(items: items)
    }

    private func buildPreviewData(
        glassFrame: CGRect,
        captureFrame: CGRect,
        scale: CGFloat
    ) -> GlassRenderer.PreviewData? {
        let state = inputNode.previewRenderState
        guard state.isActive, state.progress > 0.001 else { return nil }

        let hPad: CGFloat = 14
        let vPad: CGFloat = 6
        let btnSize: CGFloat = 48
        let spacing: CGFloat = 8
        let contentY = glassFrame.origin.y + vPad
        let textX = glassFrame.origin.x + hPad + btnSize + spacing
        let textW = glassFrame.width - hPad * 2 - btnSize * 2 - spacing * 2
        let cardFrame = previewCardFrame(
            glassFrame: glassFrame,
            contentY: contentY,
            textX: textX,
            textW: textW
        )

        guard cardFrame.width > 1,
              cardFrame.height > 1,
              let texture = previewTextRenderer.texture(
                for: state,
                size: cardFrame.size,
                scale: scale
              )
        else {
            return nil
        }

        return GlassRenderer.PreviewData(
            textRect: normalizedRect(cardFrame, in: captureFrame),
            mode: Float(state.mode.rawValue),
            opacity: Float(min(1, max(0, state.progress))),
            accentColor: previewAccentColor(for: state.mode),
            texture: texture
        )
    }

    private func previewCardFrame(
        glassFrame: CGRect,
        contentY: CGFloat,
        textX: CGFloat,
        textW: CGFloat
    ) -> CGRect {
        let cardHeight = inputNode.previewCardHeight
        let cardBottom = contentY + inputNode.previewRevealHeight - inputNode.previewBottomGap
        return CGRect(
            x: textX + inputNode.previewOuterHorizontalInset,
            y: cardBottom - cardHeight,
            width: max(1, textW - inputNode.previewOuterHorizontalInset * 2),
            height: cardHeight
        )
    }

    private func previewAccentColor(for mode: ChatInputNode.PreviewRenderMode) -> SIMD4<Float> {
        switch mode {
        case .none, .reply:
            return resolvedRGBA(AppColor.accent)
        case .forward:
            return resolvedRGBA(UIColor.dynamic(
                light: UIColor(hex: 0x0EA5E9),
                dark: UIColor(hex: 0x38BDF8)
            ))
        case .edit:
            return resolvedRGBA(UIColor.dynamic(
                light: UIColor(hex: 0xF59E0B),
                dark: UIColor(hex: 0xFBBF24)
            ))
        }
    }

    private func staticGlyph(
        source: GlassGlyphKind,
        center: CGPoint,
        iconSize: CGFloat,
        effectSize: CGFloat,
        opacity: Float = 1,
        captureFrame: CGRect
    ) -> GlassRenderer.GlyphItem {
        GlassRenderer.GlyphItem(
            rect: normalizedRect(centeredAt: center, size: iconSize, in: captureFrame),
            effectRect: normalizedRect(centeredAt: center, size: effectSize, in: captureFrame),
            source: source,
            opacity: opacity
        )
    }

    private func normalizedRect(centeredAt center: CGPoint, size: CGFloat, in captureFrame: CGRect) -> SIMD4<Float> {
        let frame = CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
        return normalizedRect(frame, in: captureFrame)
    }

    private func normalizedRect(_ frame: CGRect, in captureFrame: CGRect) -> SIMD4<Float> {
        return SIMD4<Float>(
            Float((frame.origin.x - captureFrame.origin.x) / captureFrame.width),
            Float((frame.origin.y - captureFrame.origin.y) / captureFrame.height),
            Float(frame.width / captureFrame.width),
            Float(frame.height / captureFrame.height)
        )
    }

    private func resolvedRGBA(_ color: UIColor) -> SIMD4<Float> {
        let resolved = color.resolvedColor(with: view.traitCollection)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(
            Float(max(0, min(1, r))),
            Float(max(0, min(1, g))),
            Float(max(0, min(1, b))),
            Float(max(0, min(1, a)))
        )
    }

    // MARK: - Scroll Button

    /// Computes the scroll button icon/tap frame + alpha based on the
    /// current spring progress, in this bar's parent view coordinates.
    private func computeScrollButtonLayout() -> (CGRect, CGFloat, CGRect, CGFloat) {
        guard scrollButtonProgress > 0.001 else {
            return (.zero, 0, .zero, 0)
        }
        let barFrame = frame
        let hPad: CGFloat = 14
        let vPad: CGFloat = 6
        let btnSize: CGFloat = 48
        let scrollR: CGFloat = btnSize / 2

        let micCX = barFrame.maxX - hPad - btnSize / 2
        let contentY = barFrame.origin.y + vPad
        let contentH = barFrame.height - vPad * 2
        let micCY = contentY + contentH - btnSize / 2

        let scrollTargetCX = micCX
        let scrollTargetCY = barFrame.origin.y - 12 - scrollR

        let t = scrollButtonProgress
        let scrollCX = micCX + (scrollTargetCX - micCX) * t
        let scrollCY = micCY + (scrollTargetCY - micCY) * t
        let radiusFactor = min(1, t * 4)
        let scrollCurrentR = scrollR * radiusFactor
        let iconSize = scrollCurrentR * 2

        let iconFrame = CGRect(
            x: scrollCX - iconSize / 2,
            y: scrollCY - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
        let tapFrame = iconFrame.insetBy(dx: -8, dy: -8)
        let tapAlpha: CGFloat = t > 0.3 ? 1 : 0
        return (iconFrame, radiusFactor, tapFrame, tapAlpha)
    }

    private func emitScrollButtonLayout() {
        let (icon, iconAlpha, tap, tapAlpha) = computeScrollButtonLayout()
        onScrollButtonLayoutChanged?(icon, iconAlpha, tap, tapAlpha)
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
            emitScrollButtonLayout()
            return
        }

        emitScrollButtonLayout()
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

private final class GlassInputPreviewTextRenderer {

    private struct CacheKey: Hashable {
        let width: Int
        let height: Int
        let mode: Int
        let title: String
        let body: String
    }

    private var cachedKey: CacheKey?
    private var cachedTexture: MTLTexture?

    func texture(
        for state: ChatInputNode.PreviewRenderState,
        size: CGSize,
        scale: CGFloat
    ) -> MTLTexture? {
        guard Thread.isMainThread else { return nil }
        let width = max(2, Int((size.width * scale).rounded(.toNearestOrAwayFromZero)))
        let height = max(2, Int((size.height * scale).rounded(.toNearestOrAwayFromZero)))
        let key = CacheKey(
            width: width,
            height: height,
            mode: state.mode.rawValue,
            title: state.title,
            body: state.body
        )
        if key == cachedKey, let cachedTexture {
            return cachedTexture
        }

        guard let alpha = makeAlphaMask(
            state: state,
            size: size,
            scale: scale,
            width: width,
            height: height
        ) else {
            return nil
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: desc) else {
            return nil
        }
        texture.label = "Glass input preview text \(width)x\(height)"

        alpha.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }

        cachedKey = key
        cachedTexture = texture
        return texture
    }

    private func makeAlphaMask(
        state: ChatInputNode.PreviewRenderState,
        size: CGSize,
        scale: CGFloat,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let didRender = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            UIGraphicsPushContext(context)
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            drawPreviewText(state: state, size: size)
            context.restoreGState()
            UIGraphicsPopContext()
            return true
        }
        guard didRender else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            alpha[index] = rgba[index * bytesPerPixel + 3]
        }
        return alpha
    }

    private func drawPreviewText(
        state: ChatInputNode.PreviewRenderState,
        size: CGSize
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.95),
            .paragraphStyle: paragraph
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13),
            .foregroundColor: UIColor.white.withAlphaComponent(0.62),
            .paragraphStyle: paragraph
        ]

        let leftInset: CGFloat = 22
        let rightButtonWidth: CGFloat = 38
        let textWidth = max(1, size.width - leftInset - rightButtonWidth - 8)
        let titleFont = titleAttributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = bodyAttributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 13)
        let titleHeight = ceil(titleFont.lineHeight)
        let bodyHeight = ceil(bodyFont.lineHeight)
        let titleY: CGFloat = 6
        let bodyY = titleY + titleHeight + 1

        (state.title as NSString).draw(
            with: CGRect(x: leftInset, y: titleY, width: textWidth, height: titleHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttributes,
            context: nil
        )
        (state.body as NSString).draw(
            with: CGRect(x: leftInset, y: bodyY, width: textWidth, height: bodyHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: bodyAttributes,
            context: nil
        )

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let image = UIImage(systemName: "xmark", withConfiguration: iconConfig) {
            let iconSize = image.size
            let buttonFrame = CGRect(
                x: size.width - 8 - 30,
                y: floor((size.height - 30) * 0.5),
                width: 30,
                height: 30
            )
            let iconFrame = CGRect(
                x: buttonFrame.midX - iconSize.width * 0.5,
                y: buttonFrame.midY - iconSize.height * 0.5,
                width: iconSize.width,
                height: iconSize.height
            )
            image.withTintColor(
                UIColor.white.withAlphaComponent(0.86),
                renderingMode: .alwaysOriginal
            ).draw(in: iconFrame)
        }
    }
}
