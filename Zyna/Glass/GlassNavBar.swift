//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Metal

private enum VoiceMotionTiming {
    private static let openingWidthCurvature: CGFloat = 1.35
    private static let openingWidthTailPower: CGFloat = 1.42
    private static let openingWidthLaunch: CGFloat = 0.09
    private static let openingHeightCurvature: CGFloat = 0.72
    private static let openingHeightTailPower: CGFloat = 1.50
    private static let openingHeightLaunch: CGFloat = 0.07

    static func openingWidth(_ value: CGFloat) -> CGFloat {
        openingSettle(
            0.0,
            1.0,
            value,
            curvature: openingWidthCurvature,
            tailPower: openingWidthTailPower,
            launch: openingWidthLaunch
        )
    }

    static func openingHeight(_ value: CGFloat) -> CGFloat {
        openingSettle(
            0.025,
            1.0,
            value,
            curvature: openingHeightCurvature,
            tailPower: openingHeightTailPower,
            launch: openingHeightLaunch
        )
    }

    static func openingContent(_ value: CGFloat) -> CGFloat {
        let body = min(openingWidth(value), openingHeight(value))
        return pow(body, 0.82)
    }

    private static func openingSettle(
        _ edge0: CGFloat,
        _ edge1: CGFloat,
        _ value: CGFloat,
        curvature: CGFloat,
        tailPower: CGFloat,
        launch: CGFloat
    ) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        let launchedT = smoothLaunch(t, window: launch)
        let curvedRemaining = (1 - launchedT) / (1 + max(0, curvature) * launchedT)
        return 1 - pow(curvedRemaining, max(1.001, tailPower))
    }

    private static func smoothLaunch(_ value: CGFloat, window: CGFloat) -> CGFloat {
        guard window > 0, value > 0, value < 1 else { return value }
        let response = 1 - exp(-value / window)
        let normalization = 1 - exp(-1 / window)
        return value * response / normalization
    }

    static func smootherstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

}

/// Glass navigation bar with 3 island shapes: back (circle), title (rounded rect), call (circle).
final class GlassNavBar: ASDisplayNode {

    private struct VoiceShapeSample {
        let width: CGFloat
        let heightProgress: CGFloat
    }

    private struct VoiceContentGeometry {
        let innerX: CGFloat
        let innerW: CGFloat
        let contentFrame: CGRect
    }

    private struct VoiceShapeAnimation {
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let opening: Bool
        let startWidth: CGFloat
        let targetWidth: CGFloat
        let startHeightProgress: CGFloat
        let targetHeightProgress: CGFloat

        func sample(at now: CFTimeInterval) -> VoiceShapeSample {
            let duration = max(duration, 0.001)
            let linear = CGFloat(min(1, max(0, (now - startTime) / duration)))
            let widthPhase = opening
                ? VoiceMotionTiming.openingWidth(linear)
                : VoiceMotionTiming.smootherstep(0.18, 1.0, linear)
            let heightPhase = opening
                ? VoiceMotionTiming.openingHeight(linear)
                : VoiceMotionTiming.smootherstep(0.0, 0.68, linear)
            return VoiceShapeSample(
                width: startWidth + (targetWidth - startWidth) * widthPhase,
                heightProgress: startHeightProgress
                    + (targetHeightProgress - startHeightProgress) * heightPhase
            )
        }
    }

    // MARK: - Public

    var onBack: (() -> Void)?
    var onCall: (() -> Void)?
    var onTitleTapped: (() -> Void)?
    var onVoicePlayPause: (() -> Void)?
    var onVoiceClose: (() -> Void)?
    var onVoiceSpeed: (() -> Void)?
    var onVoiceSeek: ((Float) -> Void)?
    var onHeightChanged: (() -> Void)?

    var name: String = "" {
        didSet { titleNode.name = name; setNeedsLayout() }
    }

    var presence: UserPresence? {
        didSet { titleNode.presence = presence; setNeedsLayout() }
    }

    var memberCount: Int? {
        didSet { titleNode.memberCount = memberCount; setNeedsLayout() }
    }

    var isTappable: Bool = false {
        didSet { titleNode.isTappable = isTappable }
    }

    var voiceState: VoiceTitleState? {
        get { storedVoiceState }
        set { setVoiceState(newValue, animated: true) }
    }

    func setVoiceState(_ state: VoiceTitleState?, animated: Bool) {
        let oldValue = storedVoiceState
        guard state != oldValue else { return }
        let oldHeight = currentBarHeight
        storedVoiceState = state
        if let state {
            applyActiveVoiceState(state, oldValue: oldValue, oldHeight: oldHeight, animated: animated)
        } else {
            beginVoiceDismissal(oldValue: oldValue, oldHeight: oldHeight, animated: animated)
        }
    }

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

    /// Total height from top of screen (safeArea + bar).
    var coveredHeight: CGFloat {
        guard let supernode else { return 0 }
        return supernode.view.safeAreaInsets.top + currentBarHeight
    }

    // MARK: - Subnodes

    let backButtonNode = AccessibleButtonNode()
    let callButtonNode = AccessibleButtonNode()
    let titleNode = PresenceTitleNode()

    // MARK: - Glass (UIView, added in didLoad)

    private let anchor = GlassAnchor()

    // MARK: - Constants

    private let compactBarHeight: CGFloat = 44
    private let expandedVoiceBarHeight: CGFloat = 76
    private let sideInset: CGFloat = 6
    private let btnSize: CGFloat = 36
    private let btnPad: CGFloat = 8
    private let cornerR: CGFloat = 20
    private let titleHPad: CGFloat = 12
    private var cachedTitleW: CGFloat = 0
    private var glassMaterial = GlassAdaptiveMaterial.light
    private var storedVoiceState: VoiceTitleState?
    private var renderedVoiceState: VoiceTitleState?
    private var voiceExpanded = false
    private var voiceModeProgress: CGFloat = 0
    private var voiceLifecycleProgress: CGFloat = 0
    private var voiceContentProgress: CGFloat = 0
    private var voiceMaterialProgress: CGFloat = 0
    private var voiceCaptureUsesExpandedBounds = false
    private var voiceModeDisplayLink: DisplayLinkToken?
    private var voiceModeAnimationStartTime: CFTimeInterval = 0
    private var voiceModeAnimationDuration: CFTimeInterval = 0.28
    private var voiceModeAnimationStartProgress: CGFloat = 0
    private var voiceModeAnimationTargetProgress: CGFloat = 0
    private var voiceLifecycleAnimationStartProgress: CGFloat = 0
    private var voiceLifecycleAnimationTargetProgress: CGFloat = 0
    private var voiceContentAnimationStartProgress: CGFloat = 0
    private var voiceContentAnimationTargetProgress: CGFloat = 0
    private var voiceMaterialAnimationStartProgress: CGFloat = 0
    private var voiceMaterialAnimationTargetProgress: CGFloat = 0
    private var voiceShapeAnimation: VoiceShapeAnimation?
    private var voiceIsDismissing = false
    private var voiceIsScrubbing = false
    private var voiceScrubProgress: Float = 0
    private var voiceScrubProgressOverrideUntil: CFTimeInterval = 0
    private var voiceModeAnimationCompletion: (() -> Void)?
    private weak var layoutParentView: UIView?
    private let voiceTextRenderer = GlassNavVoiceTextRenderer()

    private var currentBarHeight: CGFloat {
        renderedVoiceState != nil && voiceExpanded ? expandedVoiceBarHeight : compactBarHeight
    }

    // MARK: - Init

    override init() {
        super.init()
        anchor.debugName = "nav"

        backButtonNode.setImage(
            AppIcon.chevronLeft.template(size: 17, weight: .semibold),
            for: .normal
        )
        backButtonNode.imageNode.tintColor = glassMaterial.glyphForeground
        backButtonNode.isAccessibilityElement = true
        backButtonNode.accessibilityLabel = "Back"
        backButtonNode.accessibilityTraits = .button
        backButtonNode.style.preferredSize = CGSize(width: btnSize, height: btnSize)

        callButtonNode.setImage(
            AppIcon.phone.template(size: 16, weight: .medium),
            for: .normal
        )
        callButtonNode.imageNode.tintColor = glassMaterial.glyphForeground
        callButtonNode.isAccessibilityElement = true
        callButtonNode.accessibilityLabel = "Call"
        callButtonNode.accessibilityTraits = .button
        callButtonNode.style.preferredSize = CGSize(width: btnSize, height: btnSize)
    }

    deinit {
        voiceModeDisplayLink?.invalidate()
    }

    // MARK: - Accessibility

    /// Override to enforce reading order: back → title → call.
    /// Without this, Texture iterates subviews and may interleave with
    /// anchor/renderer or sort by frame in unexpected ways.
    var accessibilityElementsInOrder: [Any] {
        guard isNodeLoaded else { return [] }

        var elements: [Any] = []
        if backButtonNode.isNodeLoaded {
            elements.append(backButtonNode.view)
        }
        if titleNode.isNodeLoaded {
            let titleElements = titleNode.accessibilityElementsInOrder
            if titleElements.isEmpty {
                elements.append(titleNode.view)
            } else {
                elements.append(contentsOf: titleElements)
            }
        }
        if callButtonNode.isNodeLoaded {
            elements.append(callButtonNode.view)
        }
        return elements
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityElementsInOrder }
        set { }
    }

    // MARK: - didLoad

    override func didLoad() {
        super.didLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.isAccessibilityElement = false

        // Glass UIView parts — below subnode views
        anchor.cornerRadius = cornerR
        anchor.updatesShapesDuringRenderOnly = true
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        anchor.captureBaseFrameProvider = { [weak self] glassFrame, scale in
            self?.captureBaseFrame(glassFrame: glassFrame, scale: scale)
        }
        anchor.glyphProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildGlyphData(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
        }
        anchor.voiceProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildVoiceData(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
        }
        anchor.onAdaptiveMaterialChanged = { [weak self] material in
            self?.applyGlassAdaptiveMaterial(material)
        }
        view.addSubview(anchor)
        anchor.accessibilityElementsHidden = true
        titleNode.onVoicePlayPauseTapped = { [weak self] in self?.onVoicePlayPause?() }
        titleNode.onVoiceCloseTapped = { [weak self] in self?.onVoiceClose?() }
        titleNode.onVoiceSpeedTapped = { [weak self] in self?.onVoiceSpeed?() }
        titleNode.onVoiceSeek = { [weak self] progress in self?.onVoiceSeek?(progress) }
        titleNode.onVoiceScrubChanged = { [weak self] isScrubbing, progress in
            self?.setVoiceScrubbing(isScrubbing, progress: progress)
        }
        titleNode.onVoiceModeTapped = { [weak self] in self?.toggleVoiceMode() }

        // Subnodes on top of renderer
        addSubnode(backButtonNode)
        addSubnode(titleNode)
        addSubnode(callButtonNode)
        backButtonNode.imageNode.alpha = 0
        callButtonNode.imageNode.alpha = 0
        applyGlassAdaptiveMaterial(anchor.adaptiveMaterial)

        view.sendSubviewToBack(anchor)

        backButtonNode.addTarget(self, action: #selector(backTapped), forControlEvents: .touchUpInside)
        callButtonNode.addTarget(self, action: #selector(callTapped), forControlEvents: .touchUpInside)
        titleNode.onTapped = { [weak self] in self?.titleTapped() }
    }

    // MARK: - Layout

    func updateLayout(in parentView: UIView) {
        layoutParentView = parentView
        let safeTop = parentView.safeAreaInsets.top
        let fullWidth = parentView.bounds.width
        let barWidth = fullWidth - sideInset * 2

        frame = CGRect(x: sideInset, y: safeTop, width: barWidth, height: currentBarHeight)
        anchor.frame = bounds
        anchor.renderHostContainerView = parentView
    }

    override func layout() {
        super.layout()
        let rect = bounds
        let cy = compactBarHeight / 2

        // Back button (left circle)
        backButtonNode.frame = CGRect(
            x: btnPad,
            y: cy - btnSize / 2,
            width: btnSize,
            height: btnSize
        )

        // Call button (right circle)
        callButtonNode.frame = CGRect(
            x: rect.width - btnPad - btnSize,
            y: cy - btnSize / 2,
            width: btnSize,
            height: btnSize
        )

        // Title (center, fitted to content)
        let maxTitleW = rect.width - (btnPad + btnSize + btnPad) * 2
        cachedTitleW = fittedTitleWidth(maxWidth: maxTitleW)
        let titleW = cachedTitleW
        let titleX = (rect.width - titleW) / 2
        titleNode.frame = CGRect(x: titleX, y: 0, width: titleW, height: currentBarHeight)
    }

    private func fittedTitleWidth(maxWidth: CGFloat) -> CGFloat {
        let fitWidth = titleNode.contentWidth
        guard fitWidth > 0 else { return maxWidth }
        return min(fitWidth + titleHPad * 2, maxWidth)
    }

    // MARK: - Actions

    @objc private func backTapped() { onBack?() }
    @objc private func callTapped() { onCall?() }

    private func titleTapped() {
        guard !voiceExpanded else { return }
        onTitleTapped?()
    }

    private func toggleVoiceMode() {
        guard voiceState != nil else { return }
        setVoiceExpanded(!voiceExpanded)
    }

    private func applyActiveVoiceState(
        _ state: VoiceTitleState,
        oldValue: VoiceTitleState?,
        oldHeight: CGFloat,
        animated: Bool
    ) {
        let startsFromIdle = oldValue == nil || renderedVoiceState == nil || voiceLifecycleProgress < 0.001
        renderedVoiceState = state
        voiceIsDismissing = false
        voiceCaptureUsesExpandedBounds = true

        if startsFromIdle {
            let shapeDuration: CFTimeInterval = 0.44
            let shapeStartWidth = currentDisplayedTitleWidth()
            let shapeStartHeightProgress = currentDisplayedHeightProgress()
            let shapeTargetWidth = expandedVoiceTitleWidth(for: state, maxWidth: currentMaxTitleWidth())
            configureVoiceShapeAnimation(
                animated: animated,
                opening: true,
                duration: shapeDuration,
                startWidth: shapeStartWidth,
                targetWidth: shapeTargetWidth,
                startHeightProgress: shapeStartHeightProgress,
                targetHeightProgress: 1
            )
            voiceExpanded = true
            voiceModeProgress = animated ? 0 : 1
            voiceLifecycleProgress = animated ? 0 : 1
            voiceContentProgress = animated ? 0 : 1
            voiceMaterialProgress = animated ? 0 : 1

            titleNode.voiceExpanded = true
            titleNode.usesMetalVoiceForeground = true
            titleNode.voiceState = state
            invalidateVoiceGeometry(oldHeight: oldHeight, animated: false, continuousCapture: false)
            if animated {
                startVoiceModeAnimation(to: 1, lifecycleTarget: 1, duration: shapeDuration)
            } else {
                GlassService.shared.setNeedsCapture()
                GlassService.shared.setNeedsRender()
            }
            return
        }

        let geometryChanged =
            abs(currentBarHeight - oldHeight) > 0.5
            || (voiceExpanded && oldValue?.title != state.title)
            || (voiceExpanded && oldValue?.subtitle != state.subtitle)
            || (voiceExpanded && oldValue?.rateText != state.rateText)

        titleNode.voiceExpanded = voiceExpanded
        titleNode.usesMetalVoiceForeground = true
        titleNode.voiceState = state
        if geometryChanged {
            invalidateVoiceGeometry(oldHeight: oldHeight, animated: false, continuousCapture: false)
        } else {
            GlassService.shared.setNeedsRender()
        }
    }

    private func beginVoiceDismissal(oldValue: VoiceTitleState?, oldHeight: CGFloat, animated: Bool) {
        guard let state = renderedVoiceState ?? oldValue else {
            renderedVoiceState = nil
            voiceIsDismissing = false
            voiceExpanded = false
            voiceModeProgress = 0
            voiceLifecycleProgress = 0
            voiceContentProgress = 0
            voiceMaterialProgress = 0
            voiceCaptureUsesExpandedBounds = false
            voiceShapeAnimation = nil
            titleNode.usesMetalVoiceForeground = false
            titleNode.collapsedTitleAlpha = 1
            titleNode.voiceState = nil
            voiceIsScrubbing = false
            voiceScrubProgressOverrideUntil = 0
            GlassService.shared.setNeedsCapture()
            return
        }

        renderedVoiceState = state
        voiceIsDismissing = true
        voiceCaptureUsesExpandedBounds = true
        let shapeDuration: CFTimeInterval = 0.28
        let shapeStartWidth = currentDisplayedTitleWidth()
        let shapeStartHeightProgress = currentDisplayedHeightProgress()
        voiceExpanded = false
        if !animated {
            voiceModeProgress = 0
            voiceLifecycleProgress = 0
            voiceContentProgress = 0
            voiceMaterialProgress = 0
        }
        titleNode.voiceExpanded = false
        titleNode.usesMetalVoiceForeground = false
        titleNode.collapsedTitleAlpha = animated ? 0 : 1
        titleNode.voiceState = nil
        voiceIsScrubbing = false
        voiceScrubProgressOverrideUntil = 0
        configureVoiceShapeAnimation(
            animated: animated,
            opening: false,
            duration: shapeDuration,
            startWidth: shapeStartWidth,
            targetWidth: fittedTitleWidth(maxWidth: currentMaxTitleWidth()),
            startHeightProgress: shapeStartHeightProgress,
            targetHeightProgress: 0
        )
        invalidateVoiceGeometry(oldHeight: oldHeight, animated: false, continuousCapture: false)

        guard animated else {
            finishVoiceDismissal()
            return
        }

        startVoiceModeAnimation(to: 0, lifecycleTarget: 0, duration: shapeDuration) { [weak self] in
            self?.finishVoiceDismissal()
        }
    }

    private func finishVoiceDismissal() {
        let oldHeight = currentBarHeight
        renderedVoiceState = nil
        voiceIsDismissing = false
        voiceExpanded = false
        voiceModeProgress = 0
        voiceLifecycleProgress = 0
        voiceContentProgress = 0
        voiceMaterialProgress = 0
        voiceCaptureUsesExpandedBounds = false
        voiceShapeAnimation = nil
        titleNode.voiceExpanded = false
        titleNode.usesMetalVoiceForeground = false
        titleNode.collapsedTitleAlpha = 1
        titleNode.voiceState = nil
        voiceIsScrubbing = false
        voiceScrubProgressOverrideUntil = 0
        invalidateVoiceGeometry(oldHeight: oldHeight, animated: false, continuousCapture: false)
        GlassService.shared.setNeedsCapture()
    }

    private func setVoiceExpanded(_ expanded: Bool) {
        guard voiceExpanded != expanded else { return }
        let oldHeight = currentBarHeight
        let shapeDuration: CFTimeInterval = expanded ? 0.38 : 0.28
        let shapeStartWidth = currentDisplayedTitleWidth()
        let shapeStartHeightProgress = currentDisplayedHeightProgress()
        voiceExpanded = expanded
        if expanded {
            voiceCaptureUsesExpandedBounds = true
        }
        titleNode.usesMetalVoiceForeground = true
        titleNode.voiceExpanded = expanded
        let shapeTargetWidth: CGFloat
        if expanded, let state = renderedVoiceState ?? voiceState {
            shapeTargetWidth = expandedVoiceTitleWidth(for: state, maxWidth: currentMaxTitleWidth())
        } else {
            shapeTargetWidth = fittedTitleWidth(maxWidth: currentMaxTitleWidth())
        }
        configureVoiceShapeAnimation(
            animated: true,
            opening: expanded,
            duration: shapeDuration,
            startWidth: shapeStartWidth,
            targetWidth: shapeTargetWidth,
            startHeightProgress: shapeStartHeightProgress,
            targetHeightProgress: expanded ? 1 : 0
        )
        invalidateVoiceGeometry(oldHeight: oldHeight, animated: false, continuousCapture: false)
        startVoiceModeAnimation(to: expanded ? 1 : 0, lifecycleTarget: 1, duration: shapeDuration) { [weak self] in
            guard let self else { return }
            if !expanded {
                self.voiceCaptureUsesExpandedBounds = false
                GlassService.shared.setNeedsCapture()
            }
        }
    }

    private func setVoiceScrubbing(_ isScrubbing: Bool, progress: Float) {
        voiceIsScrubbing = isScrubbing
        voiceScrubProgress = min(max(progress, 0), 1)
        if isScrubbing {
            voiceScrubProgressOverrideUntil = .greatestFiniteMagnitude
            GlassService.shared.renderFor(duration: 0.12)
        } else {
            voiceScrubProgressOverrideUntil = CACurrentMediaTime() + 0.18
            GlassService.shared.renderFor(duration: 0.18)
        }
        GlassService.shared.setNeedsRender()
    }

    private func invalidateVoiceGeometry(
        oldHeight: CGFloat,
        animated: Bool = false,
        continuousCapture: Bool = true
    ) {
        let heightChanged = abs(currentBarHeight - oldHeight) > 0.5
        if continuousCapture {
            GlassService.shared.captureFor(duration: IOS26Spring.duration + 0.1)
        }

        let updates = { [weak self] in
            guard let self else { return }
            let parentView = self.layoutParentView ?? self.view.superview
            parentView?.setNeedsLayout()
            self.setNeedsLayout()
            parentView?.layoutIfNeeded()
            self.layoutIfNeeded()
            if heightChanged {
                self.onHeightChanged?()
            }
        }

        guard animated, view.window != nil else {
            updates()
            GlassService.shared.setNeedsCapture()
            return
        }

        UIView.animate(
            withDuration: IOS26Spring.duration,
            delay: 0,
            usingSpringWithDamping: 0.92,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
            animations: updates
        )
        GlassService.shared.setNeedsCapture()
    }

    private func startVoiceModeAnimation(
        to target: CGFloat,
        lifecycleTarget: CGFloat? = nil,
        duration: CFTimeInterval = 0.28,
        completion: (() -> Void)? = nil
    ) {
        let clampedTarget = min(max(target, 0), 1)
        let clampedLifecycleTarget = min(max(lifecycleTarget ?? voiceLifecycleProgress, 0), 1)
        let activeExpandedTarget = min(clampedTarget, clampedLifecycleTarget)
        voiceModeAnimationCompletion = completion
        voiceModeAnimationStartProgress = voiceModeProgress
        voiceModeAnimationTargetProgress = clampedTarget
        voiceLifecycleAnimationStartProgress = voiceLifecycleProgress
        voiceLifecycleAnimationTargetProgress = clampedLifecycleTarget
        voiceContentAnimationStartProgress = voiceContentProgress
        voiceContentAnimationTargetProgress = activeExpandedTarget
        voiceMaterialAnimationStartProgress = voiceMaterialProgress
        voiceMaterialAnimationTargetProgress = activeExpandedTarget
        voiceModeAnimationStartTime = CACurrentMediaTime()
        voiceModeAnimationDuration = duration

        guard view.window != nil,
              abs(voiceModeAnimationTargetProgress - voiceModeAnimationStartProgress) > 0.001
                || abs(voiceLifecycleAnimationTargetProgress - voiceLifecycleAnimationStartProgress) > 0.001
                || abs(voiceContentAnimationTargetProgress - voiceContentAnimationStartProgress) > 0.001
                || abs(voiceMaterialAnimationTargetProgress - voiceMaterialAnimationStartProgress) > 0.001
        else {
            stopVoiceModeAnimation(runCompletion: false)
            voiceModeProgress = clampedTarget
            voiceLifecycleProgress = clampedLifecycleTarget
            voiceContentProgress = activeExpandedTarget
            voiceMaterialProgress = activeExpandedTarget
            voiceShapeAnimation = nil
            GlassService.shared.setNeedsRender()
            completion?()
            return
        }

        voiceModeDisplayLink?.invalidate()
        voiceModeDisplayLink = DisplayLinkDriver.shared.subscribe(rate: .max) { [weak self] _ in
            self?.voiceModeAnimationTick()
        }
        GlassService.shared.renderFor(duration: duration + 0.04)
        GlassService.shared.setNeedsRender()
    }

    private func stopVoiceModeAnimation(runCompletion: Bool = true) {
        voiceModeDisplayLink?.invalidate()
        voiceModeDisplayLink = nil
        let completion = voiceModeAnimationCompletion
        voiceModeAnimationCompletion = nil
        if runCompletion {
            completion?()
        }
    }

    private func voiceModeAnimationTick() {
        let duration = max(voiceModeAnimationDuration, 0.001)
        let elapsed = CACurrentMediaTime() - voiceModeAnimationStartTime
        let linear = CGFloat(min(1, max(0, elapsed / duration)))
        let opening =
            voiceModeAnimationTargetProgress > voiceModeAnimationStartProgress
            || voiceLifecycleAnimationTargetProgress > voiceLifecycleAnimationStartProgress
        let heightPhase = opening
            ? VoiceMotionTiming.openingHeight(linear)
            : VoiceMotionTiming.smootherstep(0.0, 0.68, linear)
        let contentPhase = opening
            ? VoiceMotionTiming.openingContent(linear)
            : VoiceMotionTiming.smoothstep(0.0, 0.28, linear)
        let materialPhase = opening
            ? VoiceMotionTiming.smoothstep(0.0, 0.58, linear)
            : VoiceMotionTiming.smoothstep(0.08, 0.62, linear)
        let lifecyclePhase = opening
            ? VoiceMotionTiming.smootherstep(0.0, 0.82, linear)
            : VoiceMotionTiming.smoothstep(0.0, 0.90, linear)

        voiceModeProgress = voiceModeAnimationStartProgress
            + (voiceModeAnimationTargetProgress - voiceModeAnimationStartProgress) * heightPhase
        voiceLifecycleProgress = voiceLifecycleAnimationStartProgress
            + (voiceLifecycleAnimationTargetProgress - voiceLifecycleAnimationStartProgress) * lifecyclePhase
        voiceContentProgress = voiceContentAnimationStartProgress
            + (voiceContentAnimationTargetProgress - voiceContentAnimationStartProgress) * contentPhase
        voiceMaterialProgress = voiceMaterialAnimationStartProgress
            + (voiceMaterialAnimationTargetProgress - voiceMaterialAnimationStartProgress) * materialPhase
        if voiceIsDismissing && !opening {
            titleNode.collapsedTitleAlpha = VoiceMotionTiming.smootherstep(0.50, 1.0, linear)
        } else {
            titleNode.collapsedTitleAlpha = 1
        }
        GlassService.shared.setNeedsRender()

        if linear >= 1 {
            voiceModeProgress = voiceModeAnimationTargetProgress
            voiceLifecycleProgress = voiceLifecycleAnimationTargetProgress
            voiceContentProgress = voiceContentAnimationTargetProgress
            voiceMaterialProgress = voiceMaterialAnimationTargetProgress
            titleNode.collapsedTitleAlpha = 1
            voiceShapeAnimation = nil
            stopVoiceModeAnimation()
            GlassService.shared.setNeedsRender()
        }
    }

    // MARK: - Multi-shape

    private func buildShapes(glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat) -> GlassRenderer.ShapeParams {
        var p = GlassRenderer.ShapeParams()
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return p }

        let cy = glassFrame.origin.y + compactBarHeight / 2

        // Back button (circle, left)
        let backCX = glassFrame.origin.x + btnPad + btnSize / 2
        let backCY = cy
        let backR = btnSize / 2

        // Call button (circle, right)
        let callCX = glassFrame.maxX - btnPad - btnSize / 2
        let callCY = cy
        let callR = btnSize / 2

        // Title (rounded rect, center). During morphs this is sampled from
        // monotonic time instead of Texture layout/cache state.
        let maxTitleW = glassFrame.width - (btnPad + btnSize + btnPad) * 2
        let visualShape = voiceVisualShape(maxWidth: maxTitleW, now: CACurrentMediaTime())
        let titleW = visualShape.width
        let titleX = glassFrame.origin.x + (glassFrame.width - titleW) / 2
        let titleY = glassFrame.origin.y
        let titleH = compactBarHeight
            + (expandedVoiceBarHeight - compactBarHeight) * visualShape.heightProgress

        // Shape 0: title (rounded rect)
        p.shape0 = SIMD4<Float>(
            Float((titleX - captureFrame.origin.x) / cw),
            Float((titleY - captureFrame.origin.y) / ch),
            Float(titleW / cw),
            Float(titleH / ch)
        )
        p.shape0cornerR = Float(cornerR * scale) / Float(ch * scale)

        // Shape 1: back button (circle)
        p.shape1 = SIMD4<Float>(
            Float((backCX - captureFrame.origin.x) / cw),
            Float((backCY - captureFrame.origin.y) / ch),
            Float(backR / ch),
            0
        )

        // Shape 2: call button (circle)
        p.shape2 = SIMD4<Float>(
            Float((callCX - captureFrame.origin.x) / cw),
            Float((callCY - captureFrame.origin.y) / ch),
            Float(callR / ch),
            0
        )

        p.shapeCount = 3
        return p
    }

    private func captureBaseFrame(glassFrame: CGRect, scale: CGFloat) -> CGRect? {
        guard voiceCaptureUsesExpandedBounds else { return nil }
        let expandedFrame = CGRect(
            x: glassFrame.origin.x,
            y: glassFrame.origin.y,
            width: glassFrame.width,
            height: max(glassFrame.height, expandedVoiceBarHeight)
        )
        return expandedFrame
    }

    private func buildVoiceData(
        glassFrame: CGRect,
        captureFrame: CGRect,
        scale: CGFloat
    ) -> GlassRenderer.VoiceData? {
        guard let voiceState = renderedVoiceState,
              voiceLifecycleProgress > 0.001
        else { return nil }

        guard captureFrame.width > 0, captureFrame.height > 0 else { return nil }

        let geometry = voiceContentGeometry(glassFrame: glassFrame)
        let contentOpacity = voiceExpandedForegroundOpacity()
        let materialOpacity = voiceExpandedMaterialOpacity()
        guard max(contentOpacity, materialOpacity) > 0.001 else { return nil }

        let textFrame = CGRect(
            x: geometry.innerX,
            y: glassFrame.origin.y + 4,
            width: geometry.innerW,
            height: 53
        )
        let waveformFrame = CGRect(
            x: geometry.innerX,
            y: glassFrame.origin.y + 10,
            width: geometry.innerW,
            height: 61
        )

        guard let textTexture = voiceTextRenderer.texture(
            for: voiceState,
            material: glassMaterial,
            size: textFrame.size,
            scale: scale
        ) else {
            return nil
        }

        let samples = Self.resampledWaveform(voiceState.waveform, count: 36)
        let displayedProgress = voiceDisplayedProgress(for: voiceState)
        return GlassRenderer.VoiceData(
            contentRect: normalizedRect(geometry.contentFrame, in: captureFrame),
            contentScale: Float(voiceContentScale()),
            contentReveal: Float(contentOpacity),
            textRect: normalizedRect(textFrame, in: captureFrame),
            waveformRect: normalizedRect(waveformFrame, in: captureFrame),
            progress: displayedProgress,
            scrubProgress: voiceIsScrubbing ? voiceScrubProgress : displayedProgress,
            isScrubbing: voiceIsScrubbing,
            opacity: Float(contentOpacity),
            materialOpacity: Float(materialOpacity),
            accentColor: resolvedRGBA(ChatBubbleThemeStore.shared.selectedTheme.actionAccentColor),
            samples: samples,
            sampleCount: samples.count,
            textTexture: textTexture
        )
    }

    private func voiceDisplayedProgress(for state: VoiceTitleState) -> Float {
        guard voiceIsScrubbing || CACurrentMediaTime() < voiceScrubProgressOverrideUntil else {
            return state.progress
        }
        return voiceScrubProgress
    }

    private func buildGlyphData(
        glassFrame: CGRect,
        captureFrame: CGRect,
        scale: CGFloat
    ) -> GlassRenderer.GlyphData? {
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return nil }

        let cy = glassFrame.origin.y + compactBarHeight / 2
        let backCenter = CGPoint(
            x: glassFrame.origin.x + btnPad + btnSize / 2,
            y: cy
        )
        let callCenter = CGPoint(
            x: glassFrame.maxX - btnPad - btnSize / 2,
            y: cy
        )

        var items: [GlassRenderer.GlyphItem] = [
            staticGlyph(
                source: .chevronLeft,
                center: backCenter,
                iconSize: 20,
                effectSize: 28,
                captureFrame: captureFrame
            ),
            staticGlyph(
                source: .phone,
                center: callCenter,
                iconSize: 20,
                effectSize: 28,
                captureFrame: captureFrame
            )
        ]

        if let voiceState = renderedVoiceState {
            let maxTitleW = glassFrame.width - (btnPad + btnSize + btnPad) * 2
            let visualTitleW = voiceVisualShape(maxWidth: maxTitleW, now: CACurrentMediaTime()).width
            let visualTitleX = glassFrame.origin.x + (glassFrame.width - visualTitleW) / 2
            let geometry = voiceContentGeometry(glassFrame: glassFrame)
            let rowCenterY = glassFrame.origin.y + 19
            let progress = min(max(voiceModeProgress, 0), 1)
            let modeW: CGFloat = 32
            let playW: CGFloat = 34
            let closeW: CGFloat = 32
            let spacing: CGFloat = 8

            let modeExpandedX = geometry.innerX + modeW / 2
            let modeCollapsedX = visualTitleX + visualTitleW - titleHPad - modeW / 2
            let modeCollapsedCenter = CGPoint(x: modeCollapsedX, y: rowCenterY)
            let modeExpandedCenter = CGPoint(x: modeExpandedX, y: rowCenterY)
            let playCenter = CGPoint(x: geometry.innerX + modeW + spacing + playW / 2, y: rowCenterY)
            let closeCenter = CGPoint(x: geometry.innerX + geometry.innerW - closeW / 2, y: rowCenterY)

            let lifecycleOpacity = min(max(voiceLifecycleProgress, 0), 1)
            let contentOpacity = voiceExpandedForegroundOpacity()
            let collapsedOpacity = voiceIsDismissing
                ? 0
                : Float((1 - VoiceMotionTiming.smoothstep(0.0, 0.42, progress)) * lifecycleOpacity)
            let expandedOpacity = Float(VoiceMotionTiming.smoothstep(0.0, 1.0, contentOpacity))
            let contentScale = voiceContentScale()
            if collapsedOpacity > 0.001 {
                items.append(
                    staticGlyph(
                        source: .chevronDown,
                        center: modeCollapsedCenter,
                        iconSize: 19,
                        effectSize: 34,
                        opacity: collapsedOpacity,
                        captureFrame: captureFrame
                    )
                )
            }
            if expandedOpacity > 0.001 {
                items.append(
                    voiceContentGlyph(
                        source: .chevronUp,
                        center: modeExpandedCenter,
                        iconSize: 19,
                        effectSize: 34,
                        opacity: expandedOpacity,
                        captureFrame: captureFrame,
                        contentFrame: geometry.contentFrame,
                        contentScale: contentScale
                    )
                )
                items.append(
                    voiceContentGlyph(
                        source: voiceState.isPlaying ? .pause : .play,
                        center: playCenter,
                        iconSize: 22,
                        effectSize: 36,
                        opacity: expandedOpacity,
                        captureFrame: captureFrame,
                        contentFrame: geometry.contentFrame,
                        contentScale: contentScale
                    )
                )
                items.append(
                    voiceContentGlyph(
                        source: .xmark,
                        center: closeCenter,
                        iconSize: 19,
                        effectSize: 34,
                        opacity: expandedOpacity,
                        captureFrame: captureFrame,
                        contentFrame: geometry.contentFrame,
                        contentScale: contentScale
                    )
                )
            }
        }

        return GlassRenderer.GlyphData(items: items)
    }

    private func configureVoiceShapeAnimation(
        animated: Bool,
        opening: Bool,
        duration: CFTimeInterval,
        startWidth: CGFloat,
        targetWidth: CGFloat,
        startHeightProgress: CGFloat,
        targetHeightProgress: CGFloat
    ) {
        guard animated, view.window != nil else {
            voiceShapeAnimation = nil
            return
        }

        voiceShapeAnimation = VoiceShapeAnimation(
            startTime: CACurrentMediaTime(),
            duration: duration,
            opening: opening,
            startWidth: startWidth,
            targetWidth: targetWidth,
            startHeightProgress: startHeightProgress,
            targetHeightProgress: targetHeightProgress
        )
    }

    private func voiceVisualShape(maxWidth: CGFloat, now: CFTimeInterval) -> VoiceShapeSample {
        if let animation = voiceShapeAnimation {
            let sample = animation.sample(at: now)
            return VoiceShapeSample(
                width: min(maxWidth, max(1, sample.width)),
                heightProgress: min(max(sample.heightProgress, 0), 1)
            )
        }

        let settledWidth: CGFloat
        if let state = renderedVoiceState, voiceExpanded {
            settledWidth = expandedVoiceTitleWidth(for: state, maxWidth: maxWidth)
        } else {
            settledWidth = fittedTitleWidth(maxWidth: maxWidth)
        }

        return VoiceShapeSample(
            width: min(maxWidth, settledWidth),
            heightProgress: renderedVoiceState != nil && voiceExpanded ? 1 : 0
        )
    }

    private func currentDisplayedTitleWidth() -> CGFloat {
        let maxWidth = currentMaxTitleWidth()
        return voiceVisualShape(maxWidth: maxWidth, now: CACurrentMediaTime()).width
    }

    private func currentDisplayedHeightProgress() -> CGFloat {
        voiceVisualShape(maxWidth: currentMaxTitleWidth(), now: CACurrentMediaTime()).heightProgress
    }

    private func voiceContentTitleWidth(maxWidth: CGFloat) -> CGFloat {
        if let state = renderedVoiceState {
            return expandedVoiceTitleWidth(for: state, maxWidth: maxWidth)
        }
        return fittedTitleWidth(maxWidth: maxWidth)
    }

    private func voiceContentGeometry(glassFrame: CGRect) -> VoiceContentGeometry {
        let maxTitleW = glassFrame.width - (btnPad + btnSize + btnPad) * 2
        let titleW = voiceContentTitleWidth(maxWidth: maxTitleW)
        let titleX = glassFrame.origin.x + (glassFrame.width - titleW) / 2
        let innerX = titleX + 12
        let innerW = max(1, titleW - 24)
        return VoiceContentGeometry(
            innerX: innerX,
            innerW: innerW,
            contentFrame: CGRect(
                x: innerX,
                y: glassFrame.origin.y + 4,
                width: innerW,
                height: 67
            )
        )
    }

    private func expandedVoiceTitleWidth(for state: VoiceTitleState, maxWidth: CGFloat) -> CGFloat {
        min(maxWidth, PresenceTitleNode.expandedVoiceContentWidth(for: state) + titleHPad * 2)
    }

    private func currentMaxTitleWidth() -> CGFloat {
        let barWidth: CGFloat
        if bounds.width > 0 {
            barWidth = bounds.width
        } else if view.bounds.width > 0 {
            barWidth = view.bounds.width
        } else {
            barWidth = UIScreen.main.bounds.width - sideInset * 2
        }
        return max(1, barWidth - (btnPad + btnSize + btnPad) * 2)
    }

    private func voiceExpandedForegroundOpacity() -> CGFloat {
        min(max(voiceContentProgress, 0), 1)
    }

    private func voiceExpandedMaterialOpacity() -> CGFloat {
        min(max(voiceMaterialProgress, 0), 1)
    }

    private func voiceContentScale() -> CGFloat {
        let reveal = min(max(voiceContentProgress, 0), 1)
        if voiceContentIsClosing() {
            let retreat = pow(1 - reveal, 0.78)
            return 1 - retreat * 0.016
        }
        let settle = pow(reveal, 1.55)
        return 1 + (1 - settle) * 0.026
    }

    private func voiceContentIsClosing() -> Bool {
        voiceModeDisplayLink != nil
            && voiceContentAnimationTargetProgress < voiceContentAnimationStartProgress
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

    private func voiceContentGlyph(
        source: GlassGlyphKind,
        center: CGPoint,
        iconSize: CGFloat,
        effectSize: CGFloat,
        opacity: Float,
        captureFrame: CGRect,
        contentFrame: CGRect,
        contentScale: CGFloat
    ) -> GlassRenderer.GlyphItem {
        let contentCenter = CGPoint(x: contentFrame.midX, y: contentFrame.midY)
        let transformedCenter = CGPoint(
            x: contentCenter.x + (center.x - contentCenter.x) * contentScale,
            y: contentCenter.y + (center.y - contentCenter.y) * contentScale
        )
        return staticGlyph(
            source: source,
            center: transformedCenter,
            iconSize: iconSize * contentScale,
            effectSize: effectSize * contentScale,
            opacity: opacity,
            captureFrame: captureFrame
        )
    }

    private func normalizedRect(centeredAt center: CGPoint, size: CGFloat, in captureFrame: CGRect) -> SIMD4<Float> {
        let frame = CGRect(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
        return SIMD4<Float>(
            Float((frame.origin.x - captureFrame.origin.x) / captureFrame.width),
            Float((frame.origin.y - captureFrame.origin.y) / captureFrame.height),
            Float(frame.width / captureFrame.width),
            Float(frame.height / captureFrame.height)
        )
    }

    private func normalizedRect(_ frame: CGRect, in captureFrame: CGRect) -> SIMD4<Float> {
        SIMD4<Float>(
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

    private static func resampledWaveform(_ waveform: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !waveform.isEmpty else {
            return [Float](repeating: 0.28, count: count)
        }
        guard waveform.count != count else { return waveform.map { min(max($0, 0), 1) } }

        var result: [Float] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let position = Float(i) / Float(max(count - 1, 1)) * Float(waveform.count - 1)
            let index = Int(position)
            let fraction = position - Float(index)
            let value: Float
            if index + 1 < waveform.count {
                value = waveform[index] * (1 - fraction) + waveform[index + 1] * fraction
            } else {
                value = waveform[index]
            }
            result.append(min(max(value, 0), 1))
        }
        return result
    }

    private func applyGlassAdaptiveMaterial(_ material: GlassAdaptiveMaterial) {
        glassMaterial = material
        let glyph = material.glyphForeground
        backButtonNode.imageNode.tintColor = glyph
        callButtonNode.imageNode.tintColor = glyph
        titleNode.applyGlassAdaptiveMaterial(material)
        GlassService.shared.setNeedsRender()
    }
}

private final class GlassNavVoiceTextRenderer {

    private struct CacheKey: Hashable {
        let width: Int
        let height: Int
        let title: String
        let subtitle: String
        let remaining: String
        let rate: String
        let appearance: Int
        let contrast: Int
    }

    private var cachedKey: CacheKey?
    private var cachedTexture: MTLTexture?

    func texture(
        for state: VoiceTitleState,
        material: GlassAdaptiveMaterial,
        size: CGSize,
        scale: CGFloat
    ) -> MTLTexture? {
        guard Thread.isMainThread else { return nil }
        let width = max(2, Int((size.width * scale).rounded(.toNearestOrAwayFromZero)))
        let height = max(2, Int((size.height * scale).rounded(.toNearestOrAwayFromZero)))
        let subtitle = state.isLoading ? String(localized: "Loading") : state.subtitle
        let key = CacheKey(
            width: width,
            height: height,
            title: state.title,
            subtitle: subtitle,
            remaining: state.remainingText,
            rate: state.rateText,
            appearance: Int((material.appearance * 100).rounded()),
            contrast: Int((material.contrast * 100).rounded())
        )
        if key == cachedKey, let cachedTexture {
            return cachedTexture
        }

        guard let rgba = makeRGBA(
            title: state.title,
            subtitle: subtitle,
            remaining: state.remainingText,
            rate: state.rateText,
            material: material,
            size: size,
            scale: scale,
            width: width,
            height: height
        ) else {
            return nil
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: desc) else {
            return nil
        }
        texture.label = "Glass nav voice text \(width)x\(height)"
        rgba.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width * 4
            )
        }

        cachedKey = key
        cachedTexture = texture
        return texture
    }

    private func makeRGBA(
        title: String,
        subtitle: String,
        remaining: String,
        rate: String,
        material: GlassAdaptiveMaterial,
        size: CGSize,
        scale: CGFloat,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
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
            draw(
                title: title,
                subtitle: subtitle,
                remaining: remaining,
                rate: rate,
                material: material,
                size: size
            )
            context.restoreGState()
            UIGraphicsPopContext()
            return true
        }
        return didRender ? rgba : nil
    }

    private func draw(
        title: String,
        subtitle: String,
        remaining: String,
        rate: String,
        material: GlassAdaptiveMaterial,
        size: CGSize
    ) {
        let speedW: CGFloat = 46
        let closeW: CGFloat = 32
        let spacing: CGFloat = 8
        let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let timeWidth = ceil((remaining as NSString).size(withAttributes: [.font: timeFont]).width)
        let speedX = size.width - closeW - spacing - speedW
        let timeX = speedX - spacing - timeWidth
        let titleX: CGFloat = 1
        let titleWidth = max(1, size.width - titleX * 2)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let centeredParagraph = NSMutableParagraphStyle()
        centeredParagraph.alignment = .center
        centeredParagraph.lineBreakMode = .byTruncatingTail

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: material.primaryForeground,
            .paragraphStyle: paragraph
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: material.secondaryForeground,
            .paragraphStyle: paragraph
        ]
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: timeFont,
            .foregroundColor: material.secondaryForeground,
            .paragraphStyle: paragraph
        ]
        let speedAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: material.glyphForeground,
            .paragraphStyle: centeredParagraph
        ]
        let inlineText = NSMutableAttributedString(
            string: title,
            attributes: titleAttributes
        )
        if !subtitle.isEmpty {
            inlineText.append(NSAttributedString(
                string: " - ",
                attributes: subtitleAttributes
            ))
            inlineText.append(NSAttributedString(
                string: subtitle,
                attributes: subtitleAttributes
            ))
        }

        inlineText.draw(
            with: CGRect(x: titleX, y: 34, width: titleWidth, height: 16),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil
        )
        (remaining as NSString).draw(
            with: CGRect(x: timeX, y: 8, width: timeWidth, height: 14),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: timeAttributes,
            context: nil
        )
        (rate as NSString).draw(
            with: CGRect(x: speedX, y: 7, width: speedW, height: 15),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: speedAttributes,
            context: nil
        )
    }
}
