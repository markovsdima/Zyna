//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

struct VoicePreviewData {
    let fileURL: URL
    let duration: TimeInterval
    let waveform: [Float]
}

final class VoicePreviewNode: ASDisplayNode {

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSend: (() -> Void)?

    private let deleteButton = ASButtonNode()
    private let playPauseButton = ASButtonNode()
    private let durationNode = ASTextNode()
    private let sendButton = ASButtonNode()
    private var waveformBars: [ASDisplayNode] = []

    private let maxBars = 32
    private var isPlaying = false

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = AppColor.voiceRecordingBackground
        setupNodes()
    }

    private func setupNodes() {
        deleteButton.setImage(AppIcon.trash.rendered(size: 22, color: AppColor.destructive), for: .normal)
        deleteButton.style.preferredSize = CGSize(width: 36, height: 36)

        playPauseButton.setImage(AppIcon.play.rendered(size: 22, color: AppColor.accent), for: .normal)
        playPauseButton.style.preferredSize = CGSize(width: 36, height: 36)

        sendButton.setImage(AppIcon.send.rendered(size: 22, weight: .semibold, color: AppColor.accent), for: .normal)
        sendButton.style.preferredSize = CGSize(width: 36, height: 36)

        for _ in 0..<maxBars {
            let bar = ASDisplayNode()
            bar.backgroundColor = AppColor.accent
            bar.cornerRadius = 1.5
            bar.style.width = ASDimension(unit: .points, value: 3)
            waveformBars.append(bar)
        }
    }

    override func didLoad() {
        super.didLoad()
        deleteButton.addTarget(self, action: #selector(deleteTapped), forControlEvents: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), forControlEvents: .touchUpInside)
        sendButton.addTarget(self, action: #selector(sendTapped), forControlEvents: .touchUpInside)
    }

    // MARK: - Public

    func configure(with data: VoicePreviewData) {
        updateDuration(data.duration)
        updateWaveform(data.waveform)
        updatePlayState(false)
    }

    func updatePlayState(_ playing: Bool) {
        isPlaying = playing
        let icon: AppIcon = playing ? .pause : .play
        playPauseButton.setImage(icon.rendered(size: 22, color: AppColor.accent), for: .normal)
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let visibleBars = waveformBars.filter { $0.style.height.value > 0 }
        let waveformStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 2,
            justifyContent: .start,
            alignItems: .center,
            children: visibleBars
        )
        waveformStack.style.flexShrink = 1
        waveformStack.style.flexGrow = 1

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .center,
            children: [deleteButton, playPauseButton, waveformStack, durationNode, sendButton]
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8),
            child: row
        )
    }

    // MARK: - Private

    private func updateDuration(_ duration: TimeInterval) {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        durationNode.attributedText = NSAttributedString(
            string: String(format: "%d:%02d", minutes, seconds),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    private func updateWaveform(_ waveform: [Float]) {
        // Resample to maxBars
        let count = waveform.count
        for (i, bar) in waveformBars.enumerated() {
            if waveform.isEmpty {
                bar.style.height = ASDimension(unit: .points, value: 0)
                bar.alpha = 0
                continue
            }
            let sampleIdx = i * count / maxBars
            if sampleIdx < count {
                let sample = waveform[sampleIdx]
                let height = max(3, CGFloat(sample) * 20)
                bar.style.height = ASDimension(unit: .points, value: height)
                bar.alpha = 1
            } else {
                bar.style.height = ASDimension(unit: .points, value: 0)
                bar.alpha = 0
            }
        }
    }

    // MARK: - Actions

    @objc private func deleteTapped() { onDelete?() }
    @objc private func playPauseTapped() {
        if isPlaying { onPause?() } else { onPlay?() }
    }
    @objc private func sendTapped() { onSend?() }
}
