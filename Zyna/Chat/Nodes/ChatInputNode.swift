//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine

final class ChatInputNode: ASDisplayNode {

    let textInputNode = ASEditableTextNode()
    let sendButtonNode = ASButtonNode()
    let micButtonNode = ASButtonNode()
    let attachButtonNode = ASButtonNode()
    private let separatorNode = ASDisplayNode()

    private let overlayNode = VoiceRecordingOverlayNode()
    private let previewNode = VoicePreviewNode()
    private let recorder = AudioRecorderService()
    private let previewPlayer = AudioPlayerService()
    private var cancellables = Set<AnyCancellable>()

    private var isTextEmpty: Bool = true
    private var isRecording: Bool = false
    private var voicePreview: VoicePreviewData?
    private var gestureState: VoiceRecordingGestureState = .idle
    private var gestureStartPoint: CGPoint = .zero

    /// Saved mic button center in self coordinates (before layout switch hides it)
    private var micCenter: CGPoint = .zero
    private var pulseView: UIView?
    private var lockView: LockIndicatorView?

    /// Thresholds for gesture recognition
    private let cancelSlideDistance: CGFloat = 120
    private let lockSlideDistance: CGFloat = 80
    private let slideDeadZone: CGFloat = 15

    // MARK: - Send-colour palette

    private var colorPalette: SendColorPaletteView?
    private var colorPaletteLongPress: UILongPressGestureRecognizer?
    private var pendingFlashTask: DispatchWorkItem?
    private static let sendButtonDefaultTint: UIColor = AppColor.accent

    var onSend: ((String, UIColor?) -> Void)?
    var onVoiceRecordingFinished: ((URL, TimeInterval, [Float]) -> Void)?
    var onAttachTapped: (() -> Void)?
    var onSizeChanged: (() -> Void)?
    var onWaveformUpdate: (([Float]) -> Void)?
    var onReplyCancelled: (() -> Void)?

    // MARK: - Reply Preview

    private let replyBackgroundNode = ASDisplayNode()
    private let replyBarNode = ASDisplayNode()
    private let replyNameNode = ASTextNode()
    private let replyBodyNode = ASTextNode()
    private let replyCancelNode = ASButtonNode()
    private var isShowingReply = false

    func setReplyPreview(senderName: String?, body: String?) {
        let showing = senderName != nil
        guard showing != isShowingReply else {
            if showing {
                updateReplyText(senderName: senderName, body: body)
            }
            return
        }
        isShowingReply = showing
        if showing {
            updateReplyText(senderName: senderName, body: body)
        }
        setNeedsLayout()
        onSizeChanged?()
    }

    private func updateReplyText(senderName: String?, body: String?) {
        replyNameNode.attributedText = NSAttributedString(
            string: senderName ?? "",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: AppColor.accent
            ]
        )
        replyBodyNode.attributedText = NSAttributedString(
            string: body ?? "",
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
        bindRecorder()

        replyCancelNode.addTarget(self, action: #selector(replyCancelTapped), forControlEvents: .touchUpInside)
    }

    @objc private func replyCancelTapped() {
        onReplyCancelled?()
    }

    private func setupNodes() {
        separatorNode.style.height = ASDimension(unit: .points, value: 0)
        separatorNode.backgroundColor = .clear

        replyBackgroundNode.backgroundColor = AppColor.inputReplyBackground
        replyBackgroundNode.cornerRadius = 20
        replyBackgroundNode.clipsToBounds = true

        replyBarNode.backgroundColor = AppColor.accent
        replyBarNode.cornerRadius = 1
        replyBarNode.style.width = ASDimension(unit: .points, value: 2)
        replyNameNode.maximumNumberOfLines = 1
        replyBodyNode.maximumNumberOfLines = 1
        replyBodyNode.truncationMode = .byTruncatingTail
        replyCancelNode.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal),
            for: .normal
        )
        replyCancelNode.style.preferredSize = CGSize(width: 30, height: 30)

        textInputNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.white
        ]
        textInputNode.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textInputNode.style.flexGrow = 1
        textInputNode.style.flexShrink = 1
        textInputNode.style.minHeight = ASDimension(unit: .points, value: 48)
        textInputNode.style.maxHeight = ASDimension(unit: .points, value: 220)
        textInputNode.scrollEnabled = false
        textInputNode.backgroundColor = .clear

        attachButtonNode.setImage(AppIcon.attach.rendered(size: 24, color: .gray), for: .normal)
        attachButtonNode.style.preferredSize = CGSize(width: 48, height: 48)

        sendButtonNode.setImage(AppIcon.send.rendered(size: 24, weight: .semibold, color: AppColor.accent), for: .normal)
        sendButtonNode.style.preferredSize = CGSize(width: 48, height: 48)

        micButtonNode.setImage(AppIcon.mic.rendered(size: 24, color: .gray), for: .normal)
        micButtonNode.style.preferredSize = CGSize(width: 48, height: 48)

        overlayNode.alpha = 0
        overlayNode.isUserInteractionEnabled = false

        overlayNode.onStop = { [weak self] in self?.finishRecording() }
        overlayNode.onCancel = { [weak self] in self?.cancelRecording() }
    }

    // MARK: - didLoad

    override func didLoad() {
        super.didLoad()
        backgroundColor = .clear
        textInputNode.delegate = self
        textInputNode.view.layer.cornerRadius = 24
        textInputNode.view.clipsToBounds = true
        sendButtonNode.addTarget(self, action: #selector(sendTapped), forControlEvents: .touchUpInside)
        attachButtonNode.addTarget(self, action: #selector(attachTapped), forControlEvents: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMicGesture(_:)))
        longPress.minimumPressDuration = 0.05
        longPress.allowableMovement = 20
        longPress.delegate = self
        view.addGestureRecognizer(longPress)

        let colorPress = UILongPressGestureRecognizer(
            target: self, action: #selector(handleSendColorGesture(_:))
        )
        colorPress.minimumPressDuration = 0.3
        colorPress.allowableMovement = .greatestFiniteMagnitude
        colorPress.delegate = self
        view.addGestureRecognizer(colorPress)
        self.colorPaletteLongPress = colorPress
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        if voicePreview != nil {
            return previewLayout(constrainedSize)
        }
        if isRecording {
            return recordingLayout(constrainedSize)
        }
        return normalLayout(constrainedSize)
    }

    private func normalLayout(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let attachSpec = ASStackLayoutSpec(
            direction: .vertical, spacing: 0, justifyContent: .end, alignItems: .center,
            children: [attachButtonNode]
        )

        let rightButton = isTextEmpty ? micButtonNode : sendButtonNode
        let rightSpec = ASStackLayoutSpec(
            direction: .vertical, spacing: 0, justifyContent: .end, alignItems: .center,
            children: [rightButton]
        )

        // Reply preview: inside the text input area with dark background
        var inputChild: ASLayoutElement = textInputNode
        if isShowingReply {
            let textColumn = ASStackLayoutSpec(
                direction: .vertical, spacing: 1, justifyContent: .start, alignItems: .start,
                children: [replyNameNode, replyBodyNode]
            )
            textColumn.style.flexShrink = 1
            textColumn.style.flexGrow = 1
            let replyRow = ASStackLayoutSpec(
                direction: .horizontal, spacing: 6, justifyContent: .start, alignItems: .center,
                children: [replyBarNode, textColumn, replyCancelNode]
            )
            let replyInset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 8, left: 12, bottom: 4, right: 8),
                child: replyRow
            )
            let replyWithBg = ASBackgroundLayoutSpec(child: replyInset, background: replyBackgroundNode)
            let replyPadded = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 4, left: 4, bottom: 0, right: 4),
                child: replyWithBg
            )

            let inputColumn = ASStackLayoutSpec(
                direction: .vertical, spacing: 0, justifyContent: .start, alignItems: .stretch,
                children: [replyPadded, textInputNode]
            )
            inputColumn.style.flexGrow = 1
            inputColumn.style.flexShrink = 1
            inputChild = inputColumn
        }

        let inputRow = ASStackLayoutSpec(
            direction: .horizontal, spacing: 8, justifyContent: .start, alignItems: .end,
            children: [attachSpec, inputChild, rightSpec]
        )

        let paddedRow = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14),
            child: inputRow
        )

        let fullStack = ASStackLayoutSpec.vertical()
        fullStack.children = [separatorNode, paddedRow]
        return fullStack
    }

    private func recordingLayout(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        overlayNode.style.height = ASDimension(unit: .points, value: 60)

        let paddedOverlay = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0),
            child: overlayNode
        )

        let fullStack = ASStackLayoutSpec.vertical()
        fullStack.children = [separatorNode, paddedOverlay]
        return fullStack
    }

    private func previewLayout(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        previewNode.style.height = ASDimension(unit: .points, value: 60)

        let paddedPreview = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0),
            child: previewNode
        )

        let fullStack = ASStackLayoutSpec.vertical()
        fullStack.children = [separatorNode, paddedPreview]
        return fullStack
    }

    // MARK: - Recorder Binding

    private func bindRecorder() {
        recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleRecorderState(state) }
            .store(in: &cancellables)

        previewPlayer.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard self?.voicePreview != nil else { return }
                self?.previewNode.updatePlayState(state.isPlaying)
            }
            .store(in: &cancellables)
    }

    private func handleRecorderState(_ state: AudioRecorderService.State) {
        switch state {
        case .idle:
            break
        case .recording(let duration, let waveform):
            overlayNode.update(state: gestureState, duration: duration, waveform: waveform)
            onWaveformUpdate?(waveform)
        case .finished(let fileURL, let duration, let waveform):
            onWaveformUpdate?([])
            if gestureState == .locked {
                showVoicePreview(VoicePreviewData(fileURL: fileURL, duration: duration, waveform: waveform))
            } else {
                onVoiceRecordingFinished?(fileURL, duration, waveform)
                hideRecording()
            }
        case .cancelled:
            onWaveformUpdate?([])
            hideRecording()
        case .error:
            onWaveformUpdate?([])
            hideRecording()
        }
    }

    // MARK: - Mic Gesture

    @objc private func handleMicGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: view)
            gestureStartPoint = point
            gestureState = .holding
            // Save mic center before layout switch
            micCenter = CGPoint(
                x: micButtonNode.view.frame.midX,
                y: micButtonNode.view.frame.midY
            )
            showRecording()
            recorder.startRecording()

        case .changed:
            let point = gesture.location(in: view)
            let dx = gestureStartPoint.x - point.x
            let dy = gestureStartPoint.y - point.y

            // Pulse follows finger upward
            if dy > 0 { updatePulsePosition(dy: dy) }

            if gestureState == .locked { return }

            if dy > lockSlideDistance {
                gestureState = .locked
                overlayNode.isUserInteractionEnabled = true
                overlayNode.update(state: .locked, duration: currentDuration, waveform: currentWaveform)
                lockView?.snapAndDismiss { }
                lockView = nil
                dismissPulse()
                setNeedsLayout()
            } else if dy > slideDeadZone {
                let progress = dy / lockSlideDistance
                lockView?.updateProgress(progress)
                positionLockView(dy: dy)
            } else if dx > slideDeadZone {
                let effectiveDx = dx - slideDeadZone
                let progress = min(1, effectiveDx / cancelSlideDistance)
                gestureState = .slidingToCancel(progress)
                lockView?.dismiss()
                lockView = nil

                if progress >= 1 {
                    gestureState = .cancelled
                    cancelRecording()
                }
            } else {
                gestureState = .holding
            }

        case .ended:
            if gestureState == .locked { return }
            if case .cancelled = gestureState { return }
            finishRecording()

        case .cancelled, .failed:
            if gestureState != .locked {
                cancelRecording()
            }

        default:
            break
        }
    }

    // MARK: - Recording State

    private func showRecording() {
        isRecording = true
        overlayNode.alpha = 1
        overlayNode.isUserInteractionEnabled = false
        setNeedsLayout()
        onSizeChanged?()
        showPulse()
        showLock()
    }

    private func hideRecording() {
        isRecording = false
        gestureState = .idle
        overlayNode.alpha = 0
        overlayNode.isUserInteractionEnabled = false
        dismissPulse()
        lockView?.dismiss()
        lockView = nil
        setNeedsLayout()
        onSizeChanged?()
    }

    // MARK: - Pulse (UIView — per-frame position tracking)

    private func showPulse() {
        let size: CGFloat = 64
        let pulse = UIView(frame: CGRect(
            x: micCenter.x - size / 2,
            y: micCenter.y - size / 2,
            width: size, height: size
        ))
        pulse.backgroundColor = AppColor.accent.withAlphaComponent(0.25)
        pulse.layer.cornerRadius = size / 2
        pulse.alpha = 0
        view.addSubview(pulse)
        pulseView = pulse

        UIView.animate(withDuration: 0.15) { pulse.alpha = 1 }

        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 1.0
        anim.toValue = 1.4
        anim.duration = 0.8
        anim.autoreverses = true
        anim.repeatCount = .infinity
        pulse.layer.add(anim, forKey: "pulse")
    }

    private func updatePulsePosition(dy: CGFloat) {
        pulseView?.center = CGPoint(x: micCenter.x, y: micCenter.y - dy)
    }

    private func dismissPulse() {
        guard let pulse = pulseView else { return }
        pulse.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.15, animations: { pulse.alpha = 0 }) { _ in
            pulse.removeFromSuperview()
        }
        pulseView = nil
    }

    // MARK: - Lock Indicator (UIView — per-frame position tracking)

    private func showLock() {
        let lock = LockIndicatorView()
        let lockSize = CGSize(width: 40, height: 80)
        lock.frame = CGRect(
            x: micCenter.x - lockSize.width / 2,
            y: micCenter.y - lockSize.height - 24,
            width: lockSize.width,
            height: lockSize.height
        )
        view.addSubview(lock)
        lock.show()
        lockView = lock
    }

    private func positionLockView(dy: CGFloat) {
        guard let lock = lockView else { return }
        let lockSize = CGSize(width: 40, height: 80)
        lock.frame.origin = CGPoint(
            x: micCenter.x - lockSize.width / 2,
            y: micCenter.y - lockSize.height - 24 - dy
        )
    }

    // MARK: - Voice Preview

    private func showVoicePreview(_ data: VoicePreviewData) {
        voicePreview = data
        isRecording = false
        overlayNode.alpha = 0
        overlayNode.isUserInteractionEnabled = false
        gestureState = .idle
        dismissPulse()
        lockView?.dismiss()
        lockView = nil

        previewNode.configure(with: data)
        previewNode.onPlay = { [weak self] in
            guard let url = self?.voicePreview?.fileURL else { return }
            self?.previewPlayer.playLocal(url: url)
        }
        previewNode.onPause = { [weak self] in
            self?.previewPlayer.pause()
        }
        previewNode.onDelete = { [weak self] in
            self?.discardVoicePreview()
        }
        previewNode.onSend = { [weak self] in
            self?.sendVoicePreview()
        }

        setNeedsLayout()
        onSizeChanged?()
    }

    private func discardVoicePreview() {
        previewPlayer.stop()
        if let url = voicePreview?.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        voicePreview = nil
        setNeedsLayout()
        onSizeChanged?()
    }

    private func sendVoicePreview() {
        previewPlayer.stop()
        if let data = voicePreview {
            onVoiceRecordingFinished?(data.fileURL, data.duration, data.waveform)
        }
        voicePreview = nil
        setNeedsLayout()
        onSizeChanged?()
    }

    private func finishRecording() {
        recorder.stopRecording()
    }

    private func cancelRecording() {
        recorder.cancelRecording()
    }

    private var currentDuration: TimeInterval {
        if case .recording(let d, _) = recorder.state { return d }
        return 0
    }

    private var currentWaveform: [Float] {
        if case .recording(_, let w) = recorder.state { return w }
        return []
    }

    // MARK: - Actions

    @objc private func attachTapped() {
        onAttachTapped?()
    }

    @objc private func sendTapped() {
        sendCurrentText(color: nil)
    }

    private func sendCurrentText(color: UIColor?) {
        let text = textInputNode.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend?(text, color)
        textInputNode.textView.text = ""
        updateTextEmptyState()
        setNeedsLayout()
        onSizeChanged?()
    }

    // MARK: - Send Colour Palette

    @objc private func handleSendColorGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            presentColorPalette()
        case .changed:
            guard let palette = colorPalette, let window = view.window else { return }
            let pointInPalette = gesture.location(in: window)
            let color = palette.updateHighlight(forPoint: pointInPalette)
            applySendButtonTint(color ?? Self.sendButtonDefaultTint)
        case .ended:
            guard let palette = colorPalette, let window = view.window else { return }
            let pointInPalette = gesture.location(in: window)
            if let color = palette.colorAt(point: pointInPalette) {
                // Released on a colour — send with that colour.
                commitSendWithColor(color)
            } else {
                // Drag-off: enter sticky mode. Palette stays, waits
                // for tap-on-color or tap-outside.
                palette.updateHighlight(forPoint: nil)
                applySendButtonTint(Self.sendButtonDefaultTint)
            }
        case .cancelled, .failed:
            dismissColorPalette()
        default:
            break
        }
    }

    private func presentColorPalette() {
        guard colorPalette == nil, let window = view.window else { return }
        let palette = SendColorPaletteView()
        palette.onColorTapped = { [weak self] color in
            self?.commitSendWithColor(color)
        }
        palette.onDismissTapped = { [weak self] in
            self?.dismissColorPalette()
        }
        let sendCenter = window.convert(sendButtonNode.view.center,
                                        from: sendButtonNode.view.superview)
        palette.present(inWindow: window, pivotInWindow: sendCenter)
        colorPalette = palette
    }

    private func dismissColorPalette() {
        colorPalette?.dismiss { [weak self] in
            self?.colorPalette = nil
        }
        applySendButtonTint(Self.sendButtonDefaultTint)
    }

    private func commitSendWithColor(_ color: UIColor) {
        applySendButtonTint(color)
        dismissColorPalette()
        sendCurrentText(color: color)
        scheduleSendButtonFlashBack()
    }

    private func applySendButtonTint(_ color: UIColor) {
        sendButtonNode.setImage(
            AppIcon.send.rendered(size: 24, weight: .semibold, color: color),
            for: .normal
        )
    }

    private func scheduleSendButtonFlashBack() {
        pendingFlashTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.transition(
                with: self.sendButtonNode.view,
                duration: SendColorPaletteConfig.sendFlashFadeOut,
                options: [.transitionCrossDissolve],
                animations: {
                    self.applySendButtonTint(Self.sendButtonDefaultTint)
                },
                completion: nil
            )
        }
        pendingFlashTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SendColorPaletteConfig.sendFlashHold, execute: task
        )
    }

    private func updateTextEmptyState() {
        let empty = textInputNode.textView.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if empty != isTextEmpty {
            isTextEmpty = empty
            setNeedsLayout()
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ChatInputNode: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: view)

        // Send-colour palette long-press: only when text is non-empty and
        // the touch is over the Send button.
        if gestureRecognizer === colorPaletteLongPress {
            guard !isTextEmpty, !isRecording, voicePreview == nil else { return false }
            return sendButtonHitRect.contains(point)
        }

        // Mic recording long-press: only when text is empty.
        guard isTextEmpty, !isRecording, voicePreview == nil else { return false }
        let micFrame = micButtonNode.view.frame.insetBy(dx: -20, dy: -20)
        let micFrameInSelf = view.convert(micFrame, from: micButtonNode.supernode?.view ?? view)
        return micFrameInSelf.contains(point)
    }

    private var sendButtonHitRect: CGRect {
        let frame = sendButtonNode.view.frame.insetBy(dx: -12, dy: -12)
        return view.convert(frame, from: sendButtonNode.supernode?.view ?? view)
    }
}

// MARK: - ASEditableTextNodeDelegate

extension ChatInputNode: ASEditableTextNodeDelegate {
    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        updateTextEmptyState()
        invalidateCalculatedLayout()
        // Enable scroll when content exceeds maxHeight, disable to allow growth
        let contentH = editableTextNode.textView.contentSize.height
        let maxH: CGFloat = 220
        let needsScroll = contentH > maxH
        if editableTextNode.scrollEnabled != needsScroll {
            editableTextNode.scrollEnabled = needsScroll
        }
        onSizeChanged?()
    }
}
