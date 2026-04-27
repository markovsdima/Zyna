//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class VoiceMessageCellNode: MessageCellNode {

    // MARK: - Icons

    private static let playOnAccent  = AppIcon.play.rendered(color: AppColor.onAccent)
    private static let playAccent    = AppIcon.play.rendered(color: AppColor.accent)
    private static let pauseOnAccent = AppIcon.pause.rendered(color: AppColor.onAccent)
    private static let pauseAccent   = AppIcon.pause.rendered(color: AppColor.accent)

    // MARK: - Subnodes

    private let flatContentNode: VoiceBubbleContentNode

    // MARK: - State

    private let mediaSource: MediaSource?
    private let totalDuration: TimeInterval
    private weak var audioPlayer: AudioPlayerService?
    private var cancellable: AnyCancellable?
    private var currentProgress: Float = 0
    private var isPlaying: Bool = false
    private let replyEventId: String?

    // MARK: - Constants

    private static let barCount = 40
    private static let bubbleInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

    init(message: ChatMessage, audioPlayer: AudioPlayerService, isGroupChat: Bool = false) {
        self.audioPlayer = audioPlayer
        self.replyEventId = message.replyInfo?.eventId

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

        let usesAccentBubbleStyle = message.isOutgoing || message.zynaAttributes.color != nil
        let bubbleForegroundColor = usesAccentBubbleStyle
            ? AppColor.bubbleForegroundOutgoing
            : AppColor.bubbleForegroundIncoming
        let bubbleTimestampColor = usesAccentBubbleStyle
            ? AppColor.bubbleTimestampOutgoing
            : AppColor.bubbleTimestampIncoming

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let forwardedHeaderText: NSAttributedString?
        if let forwarderName = message.zynaAttributes.forwardedFrom {
            forwardedHeaderText = NSAttributedString(
                string: "↗ " + String(localized: "Forwarded from \(forwarderName)"),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: bubbleTimestampColor,
                    .paragraphStyle: paragraph
                ]
            )
        } else {
            forwardedHeaderText = nil
        }

        let replyHeaderData: VoiceBubbleContentNode.ReplyHeaderData?
        if let replyInfo = message.replyInfo {
            replyHeaderData = VoiceBubbleContentNode.ReplyHeaderData(
                senderText: NSAttributedString(
                    string: (replyInfo.senderDisplayName ?? replyInfo.senderId).isEmpty
                        ? "Unknown"
                        : (replyInfo.senderDisplayName ?? replyInfo.senderId),
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: usesAccentBubbleStyle
                            ? AppColor.replySenderOutgoing
                            : AppColor.replySenderIncoming,
                        .paragraphStyle: paragraph
                    ]
                ),
                bodyText: NSAttributedString(
                    string: replyInfo.body.isEmpty ? "Message" : replyInfo.body,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 12),
                        .foregroundColor: usesAccentBubbleStyle
                            ? AppColor.replyBodyOutgoing
                            : AppColor.replyBodyIncoming,
                        .paragraphStyle: paragraph
                    ]
                ),
                barColor: usesAccentBubbleStyle ? AppColor.replyBarOutgoing : AppColor.replyBarIncoming
            )
        } else {
            replyHeaderData = nil
        }

        let samples = Self.resampleWaveform(waveformData, to: Self.barCount)
        let maxContentWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio - Self.bubbleInsets.left - Self.bubbleInsets.right
        let statusIcon = message.isOutgoing
            ? MessageStatusIcon.from(sendStatus: message.sendStatus)
            : nil

        self.flatContentNode = VoiceBubbleContentNode(
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeaderData,
            durationText: Self.durationString(duration: self.totalDuration, color: bubbleForegroundColor),
            timeText: NSAttributedString(
                string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: bubbleTimestampColor
                ]
            ),
            statusIcon: statusIcon,
            statusTintColor: bubbleTimestampColor,
            waveformSamples: samples,
            waveformFilledColor: usesAccentBubbleStyle ? AppColor.onAccent : AppColor.accent,
            waveformUnfilledColor: usesAccentBubbleStyle
                ? AppColor.onAccent.withAlphaComponent(0.4)
                : AppColor.accent.withAlphaComponent(0.3),
            playImageWhenPaused: usesAccentBubbleStyle ? Self.playOnAccent : Self.playAccent,
            playImageWhenPlaying: usesAccentBubbleStyle ? Self.pauseOnAccent : Self.pauseAccent,
            maxContentWidth: maxContentWidth
        )

        super.init(message: message, isGroupChat: isGroupChat)

        flatContentNode.style.maxWidth = ASDimension(unit: .points, value: maxContentWidth)

        contextSourceNode.onQuickTap = { [weak self] point in
            guard let self, self.isNodeLoaded else { return }
            let localPoint = self.contextSourceNode.view.convert(point, to: self.flatContentNode.view)
            if let replyEventId = self.replyEventId,
               let replyFrame = self.flatContentNode.replyHeaderFrame,
               replyFrame.contains(localPoint) {
                self.onReplyHeaderTapped?(replyEventId)
                return
            }
            if self.flatContentNode.playButtonFrame.contains(localPoint) {
                self.playTapped()
            }
        }

        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASInsetLayoutSpec(insets: Self.bubbleInsets, child: self.flatContentNode)
        }

        observePlayer()
    }

    override func updateSendStatus(_ status: String) {
        super.updateSendStatus(status)
        flatContentNode.statusIcon = statusIcon(forSendStatus: status)
    }

    override func didLoad() {
        super.didLoad()
        assignProbeName("voiceMessage.flatContent", to: flatContentNode)
    }

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
                    self.flatContentNode.isPlaying = playing
                }

                if progress != self.currentProgress {
                    self.currentProgress = progress
                    self.flatContentNode.waveformProgress = progress
                    self.flatContentNode.durationText = Self.durationString(
                        duration: progress > 0 && progress < 1
                            ? self.totalDuration * (1 - TimeInterval(progress))
                            : self.totalDuration,
                        color: self.bubbleForegroundColor
                    )
                }
            }
    }

    @objc private func playTapped() {
        guard let mediaSource else { return }
        audioPlayer?.togglePlayPause(source: mediaSource)
    }

    override func accessibilityActivate() -> Bool {
        playTapped()
        return true
    }

    private static func durationString(duration: TimeInterval, color: UIColor) -> NSAttributedString {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let text = String(format: "%d:%02d", minutes, seconds)
        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: color
            ]
        )
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
