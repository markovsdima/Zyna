//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class VoiceMessageCellNode: MessageCellNode {

    // MARK: - Icons (pre-rendered once, thread-safe)

    // Pre-rendered with the brand's accent / on-accent so the icons
    // pick up theme overrides without re-rendering at use time.
    private static let playOnAccent  = AppIcon.play.rendered(color: AppColor.onAccent)
    private static let playAccent    = AppIcon.play.rendered(color: AppColor.accent)
    private static let pauseOnAccent = AppIcon.pause.rendered(color: AppColor.onAccent)
    private static let pauseAccent   = AppIcon.pause.rendered(color: AppColor.accent)

    // MARK: - Subnodes

    private let playControlNode = ASControlNode()
    private let playIconNode = ASImageNode()
    private let durationNode = ASTextNode()
    private let waveformNode: WaveformNode

    // MARK: - State

    private let mediaSource: MediaSource?
    private let totalDuration: TimeInterval
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

        let waveformData: [UInt16]
        if case .voice(let source, let duration, let waveform) = message.content {
            self.mediaSource = source
            self.totalDuration = duration
            waveformData = waveform
        } else {
            assertionFailure("VoiceMessageCellNode requires voice content")
            self.mediaSource = nil
            self.totalDuration = 0
            waveformData = []
        }

        let samples = Self.resampleWaveform(waveformData, to: Self.barCount)
        let isOutgoing = message.isOutgoing
        self.waveformNode = WaveformNode(
            samples: samples,
            filledColor: isOutgoing ? AppColor.onAccent : AppColor.accent,
            unfilledColor: isOutgoing
                ? AppColor.onAccent.withAlphaComponent(0.4)
                : AppColor.accent.withAlphaComponent(0.3)
        )

        super.init(message: message, isGroupChat: isGroupChat)

        contextSourceNode.shouldBegin = { [weak self] point in
            guard let self, self.isNodeLoaded else { return true }
            let buttonPoint = self.contextSourceNode.view.convert(point, to: self.playControlNode.view)
            return !self.playControlNode.view.bounds.contains(buttonPoint)
        }

        setupSubnodes()
        observePlayer()
    }

    // MARK: - Setup

    private func setupSubnodes() {
        // Play button
        playIconNode.image = isOutgoing ? Self.playOnAccent : Self.playAccent
        playIconNode.contentMode = .center
        playIconNode.isUserInteractionEnabled = false
        playControlNode.automaticallyManagesSubnodes = true
        playControlNode.style.preferredSize = CGSize(width: 32, height: 32)
        playControlNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: [], child: self.playIconNode)
        }

        // Duration
        durationNode.attributedText = Self.durationString(totalDuration, isOutgoing: isOutgoing)

        // Waveform
        let waveformSize = WaveformNode.size(for: Self.barCount)
        waveformNode.style.preferredSize = waveformSize

        // Bubble
        bubbleNode.isUserInteractionEnabled = true
        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return self.bubbleLayout()
        }
    }

    override func didLoad() {
        super.didLoad()
        playControlNode.addTarget(self, action: #selector(playTapped), forControlEvents: .touchUpInside)
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
                    self.updatePlayIcon(playing: playing)
                }

                if progress != self.currentProgress {
                    self.currentProgress = progress
                    self.waveformNode.updateProgress(progress)
                    self.updateDurationLabel(progress: progress)
                }
            }
    }

    // MARK: - Bubble Layout

    private func bubbleLayout() -> ASLayoutSpec {
        waveformNode.style.flexShrink = 1

        let contentRow = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 8,
            justifyContent: .start,
            alignItems: .center,
            children: [playControlNode, waveformNode, durationNode]
        )

        let timeSpec = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 0,
            justifyContent: .end,
            alignItems: .end,
            children: [timeNode]
        )

        var stackChildren: [ASLayoutElement] = []
        if let fwd = forwardedHeaderNode {
            stackChildren.append(fwd)
        }
        if let replyHeader = replyHeaderNode {
            stackChildren.append(replyHeader)
        }
        stackChildren.append(contentRow)
        stackChildren.append(timeSpec)

        let fullStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .start,
            alignItems: .stretch,
            children: stackChildren
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

    private func updatePlayIcon(playing: Bool) {
        if isOutgoing {
            playIconNode.image = playing ? Self.pauseOnAccent : Self.playOnAccent
        } else {
            playIconNode.image = playing ? Self.pauseAccent : Self.playAccent
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
            .foregroundColor: isOutgoing ? AppColor.bubbleForegroundOutgoing : AppColor.bubbleForegroundIncoming
        ])
    }

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
