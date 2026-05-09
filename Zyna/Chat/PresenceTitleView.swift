//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

struct VoiceTitleState: Equatable {
    let title: String
    let subtitle: String
    let remainingText: String
    let rateText: String
    let waveform: [Float]
    let progress: Float
    let isPlaying: Bool
    let isLoading: Bool
}

final class PresenceTitleNode: ASDisplayNode {

    var name: String = "" {
        didSet {
            nameNode.attributedText = NSAttributedString(
                string: name,
                attributes: nameAttributes
            )
            invalidateCalculatedLayout()
            updateAccessibility()
        }
    }

    var presence: UserPresence? {
        didSet { updateStatus() }
    }

    var memberCount: Int? {
        didSet { updateStatus() }
    }

    var isTappable = false {
        didSet { updateAccessibility() }
    }

    var onTapped: (() -> Void)?
    var onVoicePlayPauseTapped: (() -> Void)?
    var onVoiceCloseTapped: (() -> Void)?
    var onVoiceSpeedTapped: (() -> Void)?
    var onVoiceSeek: ((Float) -> Void)?
    var onVoiceScrubChanged: ((Bool, Float) -> Void)?
    var onVoiceModeTapped: (() -> Void)?

    var voiceState: VoiceTitleState? {
        didSet {
            guard voiceState != oldValue else { return }
            let shouldInvalidateLayout =
                (oldValue == nil) != (voiceState == nil)
                || (voiceExpanded && oldValue?.title != voiceState?.title)
                || (voiceExpanded && oldValue?.subtitle != voiceState?.subtitle)
                || (voiceExpanded && oldValue?.rateText != voiceState?.rateText)
                || oldValue?.isLoading != voiceState?.isLoading
            applyVoiceState()
            if shouldInvalidateLayout {
                invalidateCalculatedLayout()
            }
            updateAccessibility()
        }
    }

    var voiceExpanded = false {
        didSet {
            guard voiceExpanded != oldValue else { return }
            applyVoiceState()
            invalidateCalculatedLayout()
            updateAccessibility()
        }
    }

    var hasVoiceState: Bool { voiceState != nil }

    var usesMetalVoiceForeground = false {
        didSet {
            guard usesMetalVoiceForeground != oldValue else { return }
            applyVoiceForegroundVisibility()
        }
    }

    /// Intrinsic width of the name/status stack (for glass shape sizing).
    var contentWidth: CGFloat {
        if let voiceState, voiceExpanded {
            return Self.expandedVoiceContentWidth(for: voiceState)
        }
        let toggleWidth: CGFloat = voiceState == nil ? 0 : Self.voiceModeButtonWidth + 6
        return baseTitleContentWidth + toggleWidth
    }

    private let nameNode = ASTextNode()
    private let statusNode = ASTextNode()
    private let voiceTitleNode = ASTextNode()
    private let voiceSubtitleNode = ASTextNode()
    private let voiceTimeNode = ASTextNode()
    private let voiceSeekNode = VoiceTitleSeekNode()
    private let voicePlayButtonNode = AccessibleButtonNode()
    private let voiceCloseButtonNode = AccessibleButtonNode()
    private let voiceSpeedButtonNode = AccessibleButtonNode()
    private let voiceModeButtonNode = AccessibleButtonNode()
    private lazy var voiceInfoAccessibilityElement = makeVoiceInfoAccessibilityElement()
    private var statusHidden = true
    private var glassMaterial = GlassAdaptiveMaterial.light
    private var lastAppliedGlassAppearance: CGFloat = -1
    private var lastAppliedGlassContrast: CGFloat = -1

    private static let expandedVoiceWidth: CGFloat = 342
    private static let expandedSeekHeight: CGFloat = 10
    private static let voiceModeButtonWidth: CGFloat = 32

    private var baseTitleContentWidth: CGFloat {
        let nameSize = nameNode.attributedText?.size() ?? .zero
        let statusSize = statusNode.attributedText?.size() ?? .zero
        return ceil(max(nameSize.width, statusSize.width))
    }

    private var nameAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: glassMaterial.primaryForeground,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                return p
            }()
        ]
    }

    private func statusAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = .center
                return p
            }()
        ]
    }

    private var voiceTitleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: glassMaterial.primaryForeground,
            .paragraphStyle: leadingParagraph()
        ]
    }

    private var voiceSubtitleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: glassMaterial.secondaryForeground,
            .paragraphStyle: leadingParagraph()
        ]
    }

    private var voiceTimeAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: glassMaterial.secondaryForeground,
            .paragraphStyle: centeredParagraph()
        ]
    }

    static func expandedVoiceContentWidth(for state: VoiceTitleState) -> CGFloat {
        let titleWidth = ceil(
            (state.title as NSString).size(
                withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold)]
            ).width
        )
        return min(expandedVoiceWidth, max(270, titleWidth + 196))
    }

    private func centeredParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    private func leadingParagraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .natural
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        isAccessibilityElement = true
        accessibilityTraits = .header
        nameNode.maximumNumberOfLines = 1
        statusNode.maximumNumberOfLines = 1
        voiceTitleNode.maximumNumberOfLines = 1
        voiceSubtitleNode.maximumNumberOfLines = 1
        voiceTimeNode.maximumNumberOfLines = 1
        voiceTitleNode.isAccessibilityElement = false
        voiceSubtitleNode.isAccessibilityElement = false
        voiceTimeNode.isAccessibilityElement = false
        voiceSeekNode.isAccessibilityElement = true
        voiceSeekNode.accessibilityLabel = String(localized: "Seek voice message")
        voiceSeekNode.accessibilityTraits = .adjustable

        voicePlayButtonNode.style.preferredSize = CGSize(width: 34, height: 34)
        voiceCloseButtonNode.style.preferredSize = CGSize(width: 32, height: 32)
        voiceSpeedButtonNode.style.preferredSize = CGSize(width: 46, height: 30)
        voiceModeButtonNode.style.preferredSize = CGSize(
            width: Self.voiceModeButtonWidth,
            height: 32
        )

        voicePlayButtonNode.accessibilityTraits = .button
        voiceCloseButtonNode.accessibilityTraits = .button
        voiceSpeedButtonNode.accessibilityTraits = .button
        voiceModeButtonNode.accessibilityTraits = .button
        voicePlayButtonNode.isHidden = true
        voiceCloseButtonNode.isHidden = true
        voiceSpeedButtonNode.isHidden = true
        voiceModeButtonNode.isHidden = true
        voicePlayButtonNode.accessibilityElementsHidden = true
        voiceCloseButtonNode.accessibilityElementsHidden = true
        voiceSpeedButtonNode.accessibilityElementsHidden = true
        voiceModeButtonNode.accessibilityElementsHidden = true
        voiceSeekNode.isUserInteractionEnabled = true
        voiceSeekNode.onSeek = { [weak self] progress in
            self?.onVoiceSeek?(progress)
        }
        voiceSeekNode.onScrubChanged = { [weak self] isScrubbing, progress in
            self?.onVoiceScrubChanged?(isScrubbing, progress)
        }
    }

    var accessibilityElementsInOrder: [Any] {
        guard isNodeLoaded else { return [] }
        guard voiceState != nil else { return [view] }

        var elements: [Any] = []
        if !voiceExpanded {
            elements.append(view)
            if voiceModeButtonNode.isNodeLoaded,
               !voiceModeButtonNode.isHidden,
               !voiceModeButtonNode.accessibilityElementsHidden {
                elements.append(voiceModeButtonNode.view)
            }
            return elements
        }

        if voiceModeButtonNode.isNodeLoaded,
           !voiceModeButtonNode.isHidden,
           !voiceModeButtonNode.accessibilityElementsHidden {
            elements.append(voiceModeButtonNode.view)
        }
        if voicePlayButtonNode.isNodeLoaded,
           !voicePlayButtonNode.isHidden,
           !voicePlayButtonNode.accessibilityElementsHidden {
            elements.append(voicePlayButtonNode.view)
        }
        updateVoiceInfoAccessibilityFrame()
        if !(voiceInfoAccessibilityElement.accessibilityLabel ?? "").isEmpty {
            elements.append(voiceInfoAccessibilityElement)
        }
        if voiceSeekNode.isNodeLoaded,
           voiceSeekNode.isUserInteractionEnabled {
            elements.append(voiceSeekNode.view)
        }
        if voiceSpeedButtonNode.isNodeLoaded,
           !voiceSpeedButtonNode.isHidden,
           !voiceSpeedButtonNode.accessibilityElementsHidden {
            elements.append(voiceSpeedButtonNode.view)
        }
        if voiceCloseButtonNode.isNodeLoaded,
           !voiceCloseButtonNode.isHidden,
           !voiceCloseButtonNode.accessibilityElementsHidden {
            elements.append(voiceCloseButtonNode.view)
        }
        return elements
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityElementsInOrder }
        set { }
    }

    private func makeVoiceInfoAccessibilityElement() -> UIAccessibilityElement {
        let element = UIAccessibilityElement(accessibilityContainer: view)
        element.accessibilityTraits = .staticText
        return element
    }

    private func updateVoiceInfoAccessibilityFrame() {
        let width = max(1, bounds.width - 24)
        let frame = CGRect(x: 12, y: 32, width: width, height: 24)
        if isNodeLoaded, view.window != nil {
            voiceInfoAccessibilityElement.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(
                frame,
                in: view
            )
        } else {
            voiceInfoAccessibilityElement.accessibilityFrameInContainerSpace = frame
        }
    }

    override func didLoad() {
        super.didLoad()
        view.isAccessibilityElement = isAccessibilityElement
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        voicePlayButtonNode.addTarget(
            self,
            action: #selector(voicePlayPauseTapped),
            forControlEvents: .touchUpInside
        )
        voiceCloseButtonNode.addTarget(
            self,
            action: #selector(voiceCloseTapped),
            forControlEvents: .touchUpInside
        )
        voiceSpeedButtonNode.addTarget(
            self,
            action: #selector(voiceSpeedTapped),
            forControlEvents: .touchUpInside
        )
        voiceModeButtonNode.addTarget(
            self,
            action: #selector(voiceModeTapped),
            forControlEvents: .touchUpInside
        )
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if hasVoiceState {
            let point = gesture.location(in: view)
            if isPointInsideVoiceControl(point) {
                return
            }
            guard !voiceExpanded else { return }
            guard isTappable else { return }
            onTapped?()
            return
        }
        guard isTappable else { return }
        onTapped?()
    }

    @objc private func voicePlayPauseTapped() {
        onVoicePlayPauseTapped?()
    }

    @objc private func voiceCloseTapped() {
        onVoiceCloseTapped?()
    }

    @objc private func voiceSpeedTapped() {
        onVoiceSpeedTapped?()
    }

    @objc private func voiceModeTapped() {
        onVoiceModeTapped?()
    }

    private func isPointInsideVoiceControl(_ point: CGPoint) -> Bool {
        let hitSlop: CGFloat = 8
        let controlNodes = [
            voicePlayButtonNode,
            voiceCloseButtonNode,
            voiceSpeedButtonNode,
            voiceModeButtonNode,
            voiceSeekNode
        ]
        return controlNodes.contains { node in
            guard node.isNodeLoaded, !node.isHidden else { return false }
            return node.frame.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
        }
    }

    override func accessibilityActivate() -> Bool {
        guard isTappable || hasVoiceState else { return false }
        onTapped?()
        return true
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        if hasVoiceState && voiceExpanded {
            return voiceLayoutSpecThatFits(constrainedSize)
        }

        return titleLayoutSpecThatFits(includingVoiceModeButton: hasVoiceState)
    }

    private func titleLayoutSpecThatFits(includingVoiceModeButton: Bool) -> ASLayoutSpec {
        var children: [ASLayoutElement] = [nameNode]
        if !statusHidden {
            children.append(statusNode)
        }
        let stack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 1,
            justifyContent: .center,
            alignItems: .center,
            children: children
        )
        guard includingVoiceModeButton else {
            return ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: .minimumXY, child: stack)
        }

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 6,
            justifyContent: .center,
            alignItems: .center,
            children: [stack, voiceModeButtonNode]
        )
        return ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: .minimumXY, child: row)
    }

    private func voiceLayoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let width = max(160, constrainedSize.max.width.isFinite ? constrainedSize.max.width : contentWidth)
        let innerWidth = max(1, width - 24)
        voiceTitleNode.style.width = ASDimension(unit: .points, value: innerWidth)
        voiceSubtitleNode.style.width = ASDimension(unit: .points, value: innerWidth)
        voiceSeekNode.style.preferredSize = CGSize(
            width: innerWidth,
            height: Self.expandedSeekHeight
        )

        let titleStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .center,
            alignItems: .start,
            children: [voiceTitleNode, voiceSubtitleNode]
        )
        titleStack.style.flexGrow = 1
        titleStack.style.flexShrink = 1
        titleStack.style.width = ASDimension(unit: .points, value: innerWidth)

        let leftControls = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .center,
            children: [voiceModeButtonNode, voicePlayButtonNode]
        )

        let rightControls = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .end,
            alignItems: .center,
            children: [voiceTimeNode, voiceSpeedButtonNode, voiceCloseButtonNode]
        )

        let topRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .spaceBetween,
            alignItems: .center,
            children: [leftControls, rightControls]
        )
        topRow.style.width = ASDimension(unit: .points, value: innerWidth)

        let stack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 1,
            justifyContent: .center,
            alignItems: .center,
            children: [topRow, titleStack, voiceSeekNode]
        )
        stack.style.width = ASDimension(unit: .points, value: innerWidth)
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12),
            child: stack
        )
    }

    private func updateStatus() {
        // DM: show presence
        if let presence {
            if presence.online {
                setStatus(String(localized: "online"), color: .systemGreen)
            } else if let lastSeen = presence.lastSeen {
                setStatus(lastSeen.presenceLastSeenString(style: .chat), color: glassMaterial.secondaryForeground)
            } else {
                hideStatus()
            }
            return
        }

        // Group: show member count
        if let memberCount {
            setStatus(String(localized: "\(memberCount) members"), color: glassMaterial.secondaryForeground)
            return
        }

        hideStatus()
    }

    private func setStatus(_ text: String, color: UIColor) {
        statusHidden = false
        statusNode.attributedText = NSAttributedString(
            string: text,
            attributes: statusAttributes(color: color)
        )
        invalidateCalculatedLayout()
        updateAccessibility()
    }

    private func hideStatus() {
        statusHidden = true
        statusNode.attributedText = nil
        invalidateCalculatedLayout()
        updateAccessibility()
    }

    private func updateAccessibility() {
        if let voiceState, voiceExpanded {
            isAccessibilityElement = false
            if isNodeLoaded {
                view.isAccessibilityElement = false
            }
            var label = voiceState.isPlaying
                ? String(localized: "Playing voice message")
                : String(localized: "Voice message")
            label += ", \(voiceState.title), \(voiceState.remainingText)"
            accessibilityLabel = label
            accessibilityTraits = [.header, .button]
            return
        }

        isAccessibilityElement = true
        if isNodeLoaded {
            view.isAccessibilityElement = true
        }
        var label = name
        if let statusText = statusNode.attributedText?.string, !statusHidden {
            label += ", \(statusText)"
        }
        accessibilityLabel = label
        accessibilityTraits = isTappable ? [.header, .button] : .header
    }

    private func applyVoiceState() {
        guard let voiceState else {
            voiceTitleNode.attributedText = nil
            voiceSubtitleNode.attributedText = nil
            voiceTimeNode.attributedText = nil
            voiceSeekNode.update(progress: 0)
            voiceInfoAccessibilityElement.accessibilityLabel = nil
            voiceInfoAccessibilityElement.accessibilityValue = nil
            voiceTitleNode.accessibilityElementsHidden = true
            voiceSubtitleNode.accessibilityElementsHidden = true
            voiceTimeNode.accessibilityElementsHidden = true
            voiceSeekNode.accessibilityElementsHidden = true
            voicePlayButtonNode.isHidden = true
            voiceCloseButtonNode.isHidden = true
            voiceSpeedButtonNode.isHidden = true
            voiceModeButtonNode.isHidden = true
            voicePlayButtonNode.accessibilityElementsHidden = true
            voiceCloseButtonNode.accessibilityElementsHidden = true
            voiceSpeedButtonNode.accessibilityElementsHidden = true
            voiceModeButtonNode.accessibilityElementsHidden = true
            applyVoiceForegroundVisibility()
            return
        }

        let subtitle = voiceState.isLoading
            ? String(localized: "Loading")
            : voiceState.subtitle
        voiceTitleNode.attributedText = NSAttributedString(
            string: voiceState.title,
            attributes: voiceTitleAttributes
        )
        voiceTitleNode.accessibilityLabel = voiceState.title
        voiceTitleNode.accessibilityElementsHidden = !voiceExpanded
        voiceSubtitleNode.attributedText = NSAttributedString(
            string: subtitle,
            attributes: voiceSubtitleAttributes
        )
        voiceSubtitleNode.accessibilityLabel = subtitle
        voiceSubtitleNode.accessibilityElementsHidden = !voiceExpanded
        voiceTimeNode.attributedText = NSAttributedString(
            string: voiceState.remainingText,
            attributes: voiceTimeAttributes
        )
        voiceTimeNode.accessibilityLabel = voiceState.remainingText
        voiceInfoAccessibilityElement.accessibilityLabel = "\(voiceState.title) - \(subtitle)"
        voiceInfoAccessibilityElement.accessibilityValue = voiceState.remainingText
        voiceTimeNode.accessibilityElementsHidden = !voiceExpanded
        voiceSeekNode.update(progress: voiceState.progress)
        voiceSeekNode.accessibilityElementsHidden = !voiceExpanded

        voiceModeButtonNode.isHidden = false
        voiceModeButtonNode.accessibilityElementsHidden = false
        let modeIcon = voiceExpanded ? AppIcon.chevronUp : AppIcon.chevronDown
        voiceModeButtonNode.setImage(
            modeIcon.template(size: 13, weight: .semibold),
            for: .normal
        )
        voiceModeButtonNode.imageNode.tintColor = glassMaterial.glyphForeground
        voiceModeButtonNode.accessibilityLabel = voiceExpanded
            ? String(localized: "Show chat title")
            : String(localized: "Show voice player")

        voicePlayButtonNode.isHidden = !voiceExpanded
        voicePlayButtonNode.accessibilityElementsHidden = !voiceExpanded
        let playIcon = voiceState.isPlaying ? AppIcon.pause : AppIcon.play
        voicePlayButtonNode.setImage(
            playIcon.template(size: 15, weight: .semibold),
            for: .normal
        )
        voicePlayButtonNode.imageNode.tintColor = glassMaterial.glyphForeground
        voicePlayButtonNode.accessibilityLabel = voiceState.isPlaying
            ? String(localized: "Pause voice message")
            : String(localized: "Play voice message")

        voiceCloseButtonNode.setImage(
            AppIcon.xmark.template(size: 13, weight: .semibold),
            for: .normal
        )
        voiceCloseButtonNode.imageNode.tintColor = glassMaterial.glyphForeground
        voiceCloseButtonNode.accessibilityLabel = String(localized: "Close voice player")
        voiceCloseButtonNode.isHidden = !voiceExpanded
        voiceCloseButtonNode.accessibilityElementsHidden = !voiceExpanded

        voiceSpeedButtonNode.setTitle(
            voiceState.rateText,
            with: UIFont.systemFont(ofSize: 12, weight: .semibold),
            with: glassMaterial.glyphForeground,
            for: .normal
        )
        voiceSpeedButtonNode.accessibilityLabel = String(localized: "Playback speed")
        voiceSpeedButtonNode.accessibilityValue = speechFriendlyRateText(voiceState.rateText)
        voiceSpeedButtonNode.isHidden = !voiceExpanded
        voiceSpeedButtonNode.accessibilityElementsHidden = !voiceExpanded
        applyVoiceForegroundVisibility()
    }

    private func speechFriendlyRateText(_ rateText: String) -> String {
        guard rateText.hasSuffix("x") else { return rateText }
        let numberText = String(rateText.dropLast())
        guard Double(numberText) != nil, !numberText.contains(".") else { return rateText }
        return numberText + " x"
    }

    private func applyVoiceForegroundVisibility() {
        let hideVoiceChrome = usesMetalVoiceForeground && voiceState != nil
        let hideExpandedForeground = hideVoiceChrome && voiceExpanded
        let expandedAlpha: CGFloat = hideExpandedForeground ? 0 : 1
        voiceTitleNode.alpha = expandedAlpha
        voiceSubtitleNode.alpha = expandedAlpha
        voiceTimeNode.alpha = expandedAlpha
        voiceModeButtonNode.imageNode.alpha = hideVoiceChrome ? 0 : 1
        voicePlayButtonNode.imageNode.alpha = hideExpandedForeground ? 0 : 1
        voiceCloseButtonNode.imageNode.alpha = hideExpandedForeground ? 0 : 1
        voiceSpeedButtonNode.titleNode.alpha = hideExpandedForeground ? 0 : 1
    }
}

extension PresenceTitleNode {
    func applyGlassAdaptiveMaterial(_ material: GlassAdaptiveMaterial) {
        guard abs(material.appearance - lastAppliedGlassAppearance) > 0.012 ||
              abs(material.contrast - lastAppliedGlassContrast) > 0.03 else {
            return
        }

        glassMaterial = material
        lastAppliedGlassAppearance = material.appearance
        lastAppliedGlassContrast = material.contrast

        nameNode.attributedText = NSAttributedString(
            string: name,
            attributes: nameAttributes
        )
        applyVoiceState()
        updateStatus()
        invalidateCalculatedLayout()
    }
}

private final class VoiceTitleSeekNode: ASDisplayNode {

    var onSeek: ((Float) -> Void)?
    var onScrubChanged: ((Bool, Float) -> Void)?

    private var progress: Float = 0

    override init() {
        super.init()
        isOpaque = false
        isUserInteractionEnabled = true
    }

    override var accessibilityValue: String? {
        get {
            let value = Int((progress * 100).rounded())
            return "\(value)%"
        }
        set { }
    }

    override func accessibilityIncrement() {
        adjustProgress(by: 0.05)
    }

    override func accessibilityDecrement() {
        adjustProgress(by: -0.05)
    }

    override func didLoad() {
        super.didLoad()
        view.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSeekTap(_:)))
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSeekPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
    }

    func update(progress: Float) {
        let clampedProgress = min(max(progress, 0), 1)
        guard self.progress != clampedProgress else { return }
        self.progress = clampedProgress
    }

    @objc private func handleSeekTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let nextProgress = progress(at: gesture.location(in: view))
        update(progress: nextProgress)
        onSeek?(nextProgress)
    }

    @objc private func handleSeekPan(_ gesture: UIPanGestureRecognizer) {
        let nextProgress = progress(at: gesture.location(in: view))
        switch gesture.state {
        case .began:
            update(progress: nextProgress)
            onScrubChanged?(true, nextProgress)
            onSeek?(nextProgress)
        case .changed:
            update(progress: nextProgress)
            onScrubChanged?(true, nextProgress)
            onSeek?(nextProgress)
        case .ended:
            update(progress: nextProgress)
            onSeek?(nextProgress)
            onScrubChanged?(false, nextProgress)
        case .cancelled, .failed:
            onScrubChanged?(false, progress)
        default:
            break
        }
    }

    private func progress(at point: CGPoint) -> Float {
        guard bounds.width > 0 else { return 0 }
        return Float(min(max(point.x / bounds.width, 0), 1))
    }

    private func adjustProgress(by delta: Float) {
        onSeek?(min(max(progress + delta, 0), 1))
    }
}
