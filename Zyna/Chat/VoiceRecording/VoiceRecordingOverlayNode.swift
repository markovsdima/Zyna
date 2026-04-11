//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class VoiceRecordingOverlayNode: ASDisplayNode {

    // MARK: - Callbacks (locked mode)

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Subnodes

    private let timerNode = ASTextNode()
    private let slideToCancelNode = ASTextNode()
    private let chevronNode = ASImageNode()
    private let stopButtonNode = ASButtonNode()
    private let cancelButtonNode = ASButtonNode()
    private let recordingDotNode = ASDisplayNode()

    /// Thin waveform bars next to timer
    private var waveformBars: [ASDisplayNode] = []
    private let maxVisibleBars = 24

    private var gestureState: VoiceRecordingGestureState = .idle

    // MARK: - Init

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = AppColor.voiceRecordingBackground
        setupNodes()
    }

    // MARK: - Setup

    private func setupNodes() {
        // Timer
        timerNode.attributedText = Self.timerString("0:00")

        // Recording dot
        recordingDotNode.backgroundColor = AppColor.destructive
        recordingDotNode.style.preferredSize = CGSize(width: 8, height: 8)
        recordingDotNode.cornerRadius = 4

        // Slide to cancel
        slideToCancelNode.attributedText = NSAttributedString(
            string: "Slide to cancel",
            attributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )

        chevronNode.image = UIImage(
            systemName: "chevron.left",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )
        chevronNode.tintColor = .secondaryLabel
        chevronNode.style.preferredSize = CGSize(width: 12, height: 14)

        // Stop button (locked mode)
        stopButtonNode.setImage(AppIcon.stop.rendered(size: 28, color: AppColor.accent), for: .normal)
        stopButtonNode.style.preferredSize = CGSize(width: 36, height: 36)

        // Cancel button (locked mode)
        cancelButtonNode.setImage(AppIcon.trash.rendered(size: 28, color: AppColor.destructive), for: .normal)
        cancelButtonNode.style.preferredSize = CGSize(width: 36, height: 36)

        // Waveform bars
        for _ in 0..<maxVisibleBars {
            let bar = ASDisplayNode()
            bar.backgroundColor = AppColor.accent
            bar.cornerRadius = 1.5
            bar.style.width = ASDimension(unit: .points, value: 3)
            waveformBars.append(bar)
        }
    }

    override func didLoad() {
        super.didLoad()
        stopButtonNode.addTarget(self, action: #selector(stopTapped), forControlEvents: .touchUpInside)
        cancelButtonNode.addTarget(self, action: #selector(cancelTapped), forControlEvents: .touchUpInside)
    }

    // MARK: - Public API

    func update(state: VoiceRecordingGestureState, duration: TimeInterval, waveform: [Float]) {
        self.gestureState = state
        timerNode.attributedText = Self.timerString(Self.formatDuration(duration))
        updateWaveformBars(waveform)
        updateSlideToCancelAlpha(state)
        setNeedsLayout()
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        switch gestureState {
        case .locked:
            return lockedLayout(constrainedSize)
        default:
            return holdingLayout(constrainedSize)
        }
    }

    private func holdingLayout(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Left: dot + timer + waveform
        let dotTimerStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 6,
            justifyContent: .start,
            alignItems: .center,
            children: [recordingDotNode, timerNode]
        )

        let visibleBars = waveformBars.filter { $0.style.height.value > 0 }
        let waveformStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 2,
            justifyContent: .start,
            alignItems: .center,
            children: visibleBars
        )

        let leftStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 10,
            justifyContent: .start,
            alignItems: .center,
            children: [dotTimerStack, waveformStack]
        )
        leftStack.style.flexShrink = 1

        // Center: chevron + "Slide to cancel"
        let slideStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 4,
            justifyContent: .center,
            alignItems: .center,
            children: [chevronNode, slideToCancelNode]
        )

        // Spacer
        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 0,
            justifyContent: .start,
            alignItems: .center,
            children: [leftStack, spacer, slideStack, spacer]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12),
            child: row
        )
    }

    private func lockedLayout(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Left: cancel
        // Center: dot + timer + waveform
        // Right: stop/send
        let dotTimerStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 6,
            justifyContent: .start,
            alignItems: .center,
            children: [recordingDotNode, timerNode]
        )

        let visibleBars = waveformBars.filter { $0.style.height.value > 0 }
        let waveformStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 2,
            justifyContent: .start,
            alignItems: .center,
            children: visibleBars
        )

        let centerStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 10,
            justifyContent: .center,
            alignItems: .center,
            children: [dotTimerStack, waveformStack]
        )
        centerStack.style.flexGrow = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .spaceBetween,
            alignItems: .center,
            children: [cancelButtonNode, centerStack, stopButtonNode]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12),
            child: row
        )
    }

    // MARK: - Private Helpers

    private func updateWaveformBars(_ waveform: [Float]) {
        let tailCount = min(waveform.count, maxVisibleBars)
        let tail = waveform.suffix(tailCount)

        for (i, bar) in waveformBars.enumerated() {
            if i < tailCount {
                let sample = tail[tail.startIndex + i]
                let height = max(3, CGFloat(sample) * 20)
                bar.style.height = ASDimension(unit: .points, value: height)
                bar.alpha = 1
            } else {
                bar.style.height = ASDimension(unit: .points, value: 0)
                bar.alpha = 0
            }
        }
    }

    private func updateSlideToCancelAlpha(_ state: VoiceRecordingGestureState) {
        switch state {
        case .slidingToCancel(let progress):
            let alpha = max(0, 1 - progress * 1.5)
            slideToCancelNode.alpha = CGFloat(alpha)
            chevronNode.alpha = CGFloat(alpha)
        case .holding:
            slideToCancelNode.alpha = 1
            chevronNode.alpha = 1
        default:
            break
        }
    }

    private static func timerString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium),
            .foregroundColor: UIColor.label
        ])
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Actions

    @objc private func stopTapped() {
        onStop?()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
