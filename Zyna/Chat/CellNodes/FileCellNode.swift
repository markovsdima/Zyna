//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class FileCellNode: MessageCellNode {

    // MARK: - Callbacks

    var onFileTapped: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onFileTapped?()
        return true
    }

    // MARK: - State

    private let mediaSource: MediaSource?
    private let filename: String
    private let mimetype: String?
    private let fileSize: UInt64?
    private let flatContentNode: FileBubbleContentNode
    private let replyEventId: String?
    private let captionNode: ASTextNode?

    enum DownloadState {
        case idle
        case downloading(progress: Double)
        case downloaded
    }

    private(set) var downloadState: DownloadState = .idle {
        didSet { updateProgressDisplay() }
    }

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        var source: MediaSource?
        var fname = "file"
        var mime: String?
        var size: UInt64?
        let captionText = message.content.visibleFileCaption

        if case .file(let src, let f, let m, let s, _) = message.content {
            source = src
            fname = f
            mime = m
            size = s
        }

        self.mediaSource = source
        self.filename = fname
        self.mimetype = mime
        self.fileSize = size
        self.replyEventId = message.replyInfo?.eventId

        let usesAccentBubbleStyle = message.isOutgoing || message.zynaAttributes.color != nil
        let bubbleForegroundColor = usesAccentBubbleStyle
            ? AppColor.bubbleForegroundOutgoing
            : AppColor.bubbleForegroundIncoming
        let bubbleTimestampColor = usesAccentBubbleStyle
            ? AppColor.bubbleTimestampOutgoing
            : AppColor.bubbleTimestampIncoming

        let ext = (fname as NSString).pathExtension.uppercased()
        let extColor = Self.colorForExtension(ext)

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

        let replyHeaderData: FileBubbleContentNode.ReplyHeaderData?
        if let replyInfo = message.replyInfo {
            replyHeaderData = FileBubbleContentNode.ReplyHeaderData(
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

        let statusIcon = message.isOutgoing
            ? MessageStatusIcon.from(sendStatus: message.sendStatus)
            : nil

        let maxContentWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio - 24

        if let captionText {
            let node = ASTextNode()
            node.attributedText = NSAttributedString(
                string: captionText,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: bubbleForegroundColor
                ]
            )
            node.maximumNumberOfLines = 0
            self.captionNode = node
        } else {
            self.captionNode = nil
        }

        self.flatContentNode = FileBubbleContentNode(
            extText: NSAttributedString(
                string: ext.isEmpty ? "FILE" : String(ext.prefix(4)),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: extColor
                ]
            ),
            filenameText: NSAttributedString(
                string: fname,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: bubbleForegroundColor,
                    .paragraphStyle: paragraph
                ]
            ),
            sizeText: NSAttributedString(
                string: Self.formattedSize(size),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12),
                    .foregroundColor: bubbleTimestampColor
                ]
            ),
            timeText: NSAttributedString(
                string: MessageCellHelpers.timeFormatter.string(from: message.timestamp),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: bubbleTimestampColor
                ]
            ),
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeaderData,
            extColor: extColor,
            iconBackgroundColor: extColor.withAlphaComponent(0.15),
            statusIcon: statusIcon,
            statusTintColor: bubbleTimestampColor,
            maxContentWidth: maxContentWidth
        )

        super.init(message: message, isGroupChat: isGroupChat)

        flatContentNode.style.maxWidth = ASDimension(unit: .points, value: maxContentWidth)

        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            let contentInset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12),
                child: self.flatContentNode
            )

            guard let captionNode = self.captionNode else {
                return contentInset
            }

            let captionInset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 0, left: 12, bottom: 10, right: 12),
                child: captionNode
            )

            let stack = ASStackLayoutSpec(
                direction: .vertical,
                spacing: 0,
                justifyContent: .start,
                alignItems: .stretch,
                children: [contentInset, captionInset]
            )
            return stack
        }

        contextSourceNode.onQuickTap = { [weak self] point in
            guard let self, self.isNodeLoaded else { return }
            let localPoint = self.contextSourceNode.view.convert(point, to: self.flatContentNode.view)
            if let replyEventId = self.replyEventId,
               let replyFrame = self.flatContentNode.replyHeaderFrame,
               replyFrame.contains(localPoint) {
                self.onReplyHeaderTapped?(replyEventId)
                return
            }
            self.onFileTapped?()
        }
    }

    override func didLoad() {
        super.didLoad()
        assignProbeName("fileMessage.flatContent", to: flatContentNode)
        if let captionNode {
            assignProbeName("fileMessage.caption", to: captionNode)
        }
    }

    override func updateSendStatus(_ status: String) {
        super.updateSendStatus(status)
        flatContentNode.statusIcon = MessageStatusIcon.from(sendStatus: status)
    }

    // MARK: - Progress

    func setDownloadState(_ state: DownloadState) {
        self.downloadState = state
    }

    private func updateProgressDisplay() {
        switch downloadState {
        case .idle:
            flatContentNode.downloadState = .idle
        case .downloading(let progress):
            flatContentNode.downloadState = .downloading(progress: progress)
        case .downloaded:
            flatContentNode.downloadState = .downloaded
        }
    }

    // MARK: - Helpers

    static func colorForExtension(_ ext: String) -> UIColor {
        switch ext.lowercased() {
        case "pdf", "ppt", "pptx":
            return .systemRed
        case "xls", "xlsx", "csv", "numbers":
            return .systemGreen
        case "zip", "rar", "7z", "gz", "tar":
            return .systemYellow
        case "doc", "docx", "txt", "rtf", "pages":
            return .systemBlue
        case "mp3", "wav", "aac", "flac", "m4a":
            return .systemPurple
        case "mp4", "mov", "avi", "mkv", "webm":
            return .systemOrange
        case "jpg", "jpeg", "png", "gif", "webp", "heic":
            return .systemTeal
        default:
            return .systemBlue
        }
    }

    static func formattedSize(_ size: UInt64?) -> String {
        guard let size else { return "Unknown size" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
