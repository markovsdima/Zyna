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
    private let recorder = AudioRecorderService()
    private var cancellables = Set<AnyCancellable>()

    private var isTextEmpty: Bool = true
    private var isRecording: Bool = false
    private var gestureState: VoiceRecordingGestureState = .idle
    private var gestureStartPoint: CGPoint = .zero

    /// Thresholds for gesture recognition
    private let cancelSlideDistance: CGFloat = 120
    private let lockSlideDistance: CGFloat = 80
    private let slideDeadZone: CGFloat = 15

    var onSend: ((String) -> Void)?
    var onVoiceRecordingFinished: ((URL, TimeInterval, [Float]) -> Void)?
    var onAttachTapped: (() -> Void)?
    var onSizeChanged: (() -> Void)?

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
        bindRecorder()
    }

    private func setupNodes() {
        separatorNode.style.height = ASDimension(unit: .points, value: 0.5)
        separatorNode.backgroundColor = .separator

        textInputNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16)
        ]
        textInputNode.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        textInputNode.style.flexGrow = 1
        textInputNode.style.flexShrink = 1
        textInputNode.style.minHeight = ASDimension(unit: .points, value: 36)
        textInputNode.style.maxHeight = ASDimension(unit: .points, value: 120)
        textInputNode.scrollEnabled = true

        textInputNode.backgroundColor = .secondarySystemBackground

        attachButtonNode.setImage(
            Self.renderSymbol("paperclip", pointSize: 22, color: .gray),
            for: .normal
        )
        attachButtonNode.style.preferredSize = CGSize(width: 36, height: 36)

        // Send button
        sendButtonNode.setImage(
            Self.renderSymbol("arrow.up.circle.fill", pointSize: 22, weight: .semibold, color: .systemBlue),
            for: .normal
        )
        sendButtonNode.style.preferredSize = CGSize(width: 36, height: 36)

        // Mic button
        micButtonNode.setImage(
            Self.renderSymbol("mic.fill", pointSize: 22, color: .gray),
            for: .normal
        )
        micButtonNode.style.preferredSize = CGSize(width: 36, height: 36)

        // Overlay is hidden by default
        overlayNode.alpha = 0
        overlayNode.isUserInteractionEnabled = false

        overlayNode.onStop = { [weak self] in
            self?.finishRecording()
        }
        overlayNode.onCancel = { [weak self] in
            self?.cancelRecording()
        }
    }

    // MARK: - didLoad

    override func didLoad() {
        super.didLoad()
        backgroundColor = .systemBackground
        textInputNode.delegate = self
        textInputNode.view.layer.cornerRadius = 18
        textInputNode.view.clipsToBounds = true
        sendButtonNode.addTarget(self, action: #selector(sendTapped), forControlEvents: .touchUpInside)
        attachButtonNode.addTarget(self, action: #selector(attachTapped), forControlEvents: .touchUpInside)

        // Long press for mic — only recognized near the mic button
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMicGesture(_:)))
        longPress.minimumPressDuration = 0.05
        longPress.allowableMovement = 20
        longPress.delegate = self
        view.addGestureRecognizer(longPress)
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        if isRecording {
            return recordingLayout(constrainedSize)
        }
        return normalLayout(constrainedSize)
    }

    private func normalLayout(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Buttons pinned to bottom (when text field expands to multiple lines)
        let attachSpec = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .end,
            alignItems: .center,
            children: [attachButtonNode]
        )

        let rightButton = isTextEmpty ? micButtonNode : sendButtonNode
        let rightSpec = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .end,
            alignItems: .center,
            children: [rightButton]
        )

        // Horizontal stack: [attach] [input] [send/mic]
        let inputRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .end,
            children: [attachSpec, textInputNode, rightSpec]
        )

        let paddedRow = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8),
            child: inputRow
        )

        // Separator + input row
        let fullStack = ASStackLayoutSpec.vertical()
        fullStack.children = [separatorNode, paddedRow]

        return fullStack
    }

    private func recordingLayout(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        overlayNode.style.height = ASDimension(unit: .points, value: 48)

        let paddedOverlay = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0),
            child: overlayNode
        )

        let fullStack = ASStackLayoutSpec.vertical()
        fullStack.children = [separatorNode, paddedOverlay]

        return fullStack
    }

    // MARK: - Recorder Binding

    private func bindRecorder() {
        recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleRecorderState(state)
            }
            .store(in: &cancellables)
    }

    private func handleRecorderState(_ state: AudioRecorderService.State) {
        switch state {
        case .idle:
            break
        case .recording(let duration, let waveform):
            overlayNode.update(state: gestureState, duration: duration, waveform: waveform)
        case .finished(let fileURL, let duration, let waveform):
            onVoiceRecordingFinished?(fileURL, duration, waveform)
            hideOverlay()
        case .cancelled:
            hideOverlay()
        case .error:
            hideOverlay()
        }
    }

    // MARK: - Mic Gesture

    @objc private func handleMicGesture(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: view)
            gestureStartPoint = point
            gestureState = .holding
            showOverlay()
            recorder.startRecording()

        case .changed:
            let point = gesture.location(in: view)
            let dx = gestureStartPoint.x - point.x  // positive = left
            let dy = gestureStartPoint.y - point.y   // positive = up

            if gestureState == .locked { return }

            if dy > lockSlideDistance {
                gestureState = .locked
                overlayNode.isUserInteractionEnabled = true
                overlayNode.update(state: .locked, duration: currentDuration, waveform: currentWaveform)
                setNeedsLayout()
            } else if dx > slideDeadZone {
                let effectiveDx = dx - slideDeadZone
                let progress = min(1, effectiveDx / cancelSlideDistance)
                gestureState = .slidingToCancel(progress)

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

    // MARK: - Recording Control

    private func showOverlay() {
        isRecording = true
        overlayNode.alpha = 1
        overlayNode.isUserInteractionEnabled = false
        setNeedsLayout()
        onSizeChanged?()
    }

    private func hideOverlay() {
        isRecording = false
        gestureState = .idle
        overlayNode.alpha = 0
        overlayNode.isUserInteractionEnabled = false
        setNeedsLayout()
        onSizeChanged?()
    }

    private func finishRecording() {
        recorder.stopRecording()
    }

    private func cancelRecording() {
        recorder.cancelRecording()
    }

    /// Convenience accessors for current recorder state
    private var currentDuration: TimeInterval {
        if case .recording(let d, _) = recorder.state { return d }
        return 0
    }

    private var currentWaveform: [Float] {
        if case .recording(_, let w) = recorder.state { return w }
        return []
    }

    // MARK: - Helpers

    private static func renderSymbol(
        _ name: String,
        pointSize: CGFloat,
        weight: UIImage.SymbolWeight = .regular,
        color: UIColor
    ) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: symbol.size)
        return renderer.image { _ in
            color.setFill()
            symbol.withRenderingMode(.alwaysTemplate).draw(at: .zero)
        }
    }

    // MARK: - Actions

    @objc private func attachTapped() {
        onAttachTapped?()
    }

    @objc private func sendTapped() {
        let text = textInputNode.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend?(text)
        textInputNode.textView.text = ""
        updateTextEmptyState()
        setNeedsLayout()
        onSizeChanged?()
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
        guard isTextEmpty else { return false }
        let point = touch.location(in: view)
        let micFrame = micButtonNode.view.frame.insetBy(dx: -20, dy: -20)
        let micFrameInSelf = view.convert(micFrame, from: micButtonNode.supernode?.view ?? view)
        return micFrameInSelf.contains(point)
    }
}

// MARK: - ASEditableTextNodeDelegate

extension ChatInputNode: ASEditableTextNodeDelegate {
    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        updateTextEmptyState()
        onSizeChanged?()
    }
}
