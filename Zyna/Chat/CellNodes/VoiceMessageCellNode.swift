//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class VoiceMessageCellNode: MessageCellNode {

    // MARK: - Subnodes

    private let playButtonNode = ASButtonNode()
    private let durationNode = ASTextNode()
    private var waveformBars: [ASDisplayNode] = []

    // MARK: - State

    private let mediaSource: MediaSource?
    private let totalDuration: TimeInterval
    private let waveform: [UInt16]
    private weak var audioPlayer: AudioPlayerService?
    private var cancellable: AnyCancellable?
    private var currentProgress: Float = 0
    private var isPlaying: Bool = false

    // MARK: - Constants

    private static let barCount = 40
    private static let bubbleInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

    // MARK: - Init

    init(message: ChatMessage, audioPlayer: AudioPlayerService, isGroupChat: Bool = false) {
        self.audioPlayer = audioPlayer

        if case .voice(let source, let duration, let waveform) = message.content {
            self.mediaSource = source
            self.totalDuration = duration
            self.waveform = waveform
        } else {
            assertionFailure("VoiceMessageCellNode requires voice content")
            self.mediaSource = nil
            self.totalDuration = 0
            self.waveform = []
        }

        super.init(message: message, isGroupChat: isGroupChat)

        contextSourceNode.shouldBegin = { [weak self] point in
            guard let self, self.isNodeLoaded else { return true }
            let buttonPoint = self.contextSourceNode.view.convert(point, to: self.playButtonNode.view)
            return !self.playButtonNode.view.bounds.contains(buttonPoint)
        }

        setupSubnodes()
        observePlayer()
    }

    // MARK: - Setup

    private func setupSubnodes() {
        // Play button
        updatePlayButtonImage(playing: false)
        playButtonNode.style.preferredSize = CGSize(width: 32, height: 32)

        // Duration
        durationNode.attributedText = Self.durationString(totalDuration, isOutgoing: isOutgoing)

        // Waveform bars
        let samples = Self.resampleWaveform(waveform, to: Self.barCount)
        for sample in samples {
            let bar = ASDisplayNode()
            bar.cornerRadius = 1.5
            bar.style.width = ASDimension(unit: .points, value: 3)
            let height = max(3, CGFloat(sample) / 1024.0 * 20)
            bar.style.height = ASDimension(unit: .points, value: height)
            bar.backgroundColor = isOutgoing
                ? UIColor.white.withAlphaComponent(0.4)
                : UIColor.systemBlue.withAlphaComponent(0.3)
            waveformBars.append(bar)
        }

        // Bubble
        bubbleNode.isUserInteractionEnabled = true
        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return self.bubbleLayout()
        }
    }

    override func didLoad() {
        super.didLoad()
        playButtonNode.addTarget(self, action: #selector(playTapped), forControlEvents: .touchUpInside)
    }

    // MARK: - Player Observation

    private func observePlayer() {
        guard let mediaSource else { return }
        let sourceKey = mediaSource.url()
        cancellable = audioPlayer?.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let isThisSource = state.sourceURL == sourceKey
                let playing = isThisSource && state.isPlaying
                let progress: Float = isThisSource ? state.progress : 0

                if playing != self.isPlaying {
                    self.isPlaying = playing
                    self.updatePlayButtonImage(playing: playing)
                }

                if progress != self.currentProgress {
                    self.currentProgress = progress
                    self.updateWaveformProgress(progress)
                    self.updateDurationLabel(progress: progress)
                }
            }
    }

    // MARK: - Bubble Layout

    private func bubbleLayout() -> ASLayoutSpec {
        let waveformStack = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 2,
            justifyContent: .start,
            alignItems: .center,
            children: waveformBars
        )
        waveformStack.style.flexShrink = 1

        let contentRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .center,
            children: [playButtonNode, waveformStack, durationNode]
        )

        let timeSpec = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 0,
            justifyContent: .end,
            alignItems: .end,
            children: [timeNode]
        )

        let fullStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .start,
            alignItems: .stretch,
            children: [contentRow, timeSpec]
        )

        return ASInsetLayoutSpec(insets: Self.bubbleInsets, child: fullStack)
    }

    // MARK: - Cell Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        bubbleNode.style.maxWidth = ASDimension(
            unit: .points,
            value: ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        )
        return super.layoutSpecThatFits(constrainedSize)
    }

    // MARK: - Actions

    @objc private func playTapped() {
        guard let mediaSource else { return }
        audioPlayer?.togglePlayPause(source: mediaSource)
    }

    // MARK: - UI Updates

    private func updatePlayButtonImage(playing: Bool) {
        let name = playing ? "pause.fill" : "play.fill"
        let color: UIColor = isOutgoing ? .white : .systemBlue
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        playButtonNode.setImage(
            UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal),
            for: .normal
        )
    }

    private func updateWaveformProgress(_ progress: Float) {
        let filledCount = Int(progress * Float(waveformBars.count))
        for (i, bar) in waveformBars.enumerated() {
            if i < filledCount {
                bar.backgroundColor = isOutgoing
                    ? UIColor.white
                    : UIColor.systemBlue
            } else {
                bar.backgroundColor = isOutgoing
                    ? UIColor.white.withAlphaComponent(0.4)
                    : UIColor.systemBlue.withAlphaComponent(0.3)
            }
        }
    }

    private func updateDurationLabel(progress: Float) {
        if progress > 0 && progress < 1 {
            let remaining = totalDuration * (1 - TimeInterval(progress))
            durationNode.attributedText = Self.durationString(remaining, isOutgoing: isOutgoing)
        } else {
            durationNode.attributedText = Self.durationString(totalDuration, isOutgoing: isOutgoing)
        }
    }

    // MARK: - Helpers

    private static func durationString(_ duration: TimeInterval, isOutgoing: Bool) -> NSAttributedString {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let text = String(format: "%d:%02d", minutes, seconds)
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: isOutgoing ? UIColor.white : UIColor.label
        ])
    }

    /// Resample a waveform array to a target count using linear interpolation.
    private static func resampleWaveform(_ waveform: [UInt16], to count: Int) -> [UInt16] {
        guard !waveform.isEmpty else {
            return [UInt16](repeating: 100, count: count)
        }
        guard waveform.count != count else { return waveform }

        var result = [UInt16]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let position = Float(i) / Float(count) * Float(waveform.count)
            let index = Int(position)
            let fraction = position - Float(index)
            let value: Float
            if index + 1 < waveform.count {
                value = Float(waveform[index]) * (1 - fraction) + Float(waveform[index + 1]) * fraction
            } else {
                value = Float(waveform[min(index, waveform.count - 1)])
            }
            result.append(UInt16(min(value, 1024)))
        }
        return result
    }
}
