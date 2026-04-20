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

    // MARK: - Subnodes

    private let iconBackgroundNode = ASDisplayNode()
    private let extensionTextNode = ASTextNode()
    private let filenameNode = ASTextNode()
    private let sizeNode = ASTextNode()
    private let progressNode = CircularProgressNode()

    // MARK: - State

    private let mediaSource: MediaSource?
    private let filename: String
    private let mimetype: String?
    private let fileSize: UInt64?

    /// Current download state, drives progress indicator visibility.
    enum DownloadState {
        case idle
        case downloading(progress: Double)
        case downloaded
    }

    private(set) var downloadState: DownloadState = .idle {
        didSet { updateProgressDisplay() }
    }

    // MARK: - Init

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        var source: MediaSource?
        var fname = "file"
        var mime: String?
        var size: UInt64?

        if case .file(let src, let f, let m, let s) = message.content {
            source = src
            fname = f
            mime = m
            size = s
        }

        self.mediaSource = source
        self.filename = fname
        self.mimetype = mime
        self.fileSize = size

        super.init(message: message, isGroupChat: isGroupChat)

        let ext = (fname as NSString).pathExtension.uppercased()
        let extColor = Self.colorForExtension(ext)

        // Icon background — colored rounded square
        iconBackgroundNode.backgroundColor = extColor.withAlphaComponent(0.15)
        iconBackgroundNode.cornerRadius = 10
        iconBackgroundNode.style.preferredSize = CGSize(width: 44, height: 44)

        // Extension label centered in icon
        extensionTextNode.attributedText = NSAttributedString(
            string: ext.isEmpty ? "FILE" : String(ext.prefix(4)),
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: extColor
            ]
        )

        // Filename
        filenameNode.maximumNumberOfLines = 1
        filenameNode.truncationMode = .byTruncatingMiddle
        filenameNode.attributedText = NSAttributedString(
            string: fname,
            attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: bubbleForegroundColor
            ]
        )

        // Size
        sizeNode.attributedText = NSAttributedString(
            string: Self.formattedSize(size),
            attributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: bubbleTimestampColor
            ]
        )

        // Progress node — hidden by default
        progressNode.style.preferredSize = CGSize(width: 44, height: 44)
        progressNode.isHidden = true
        progressNode.trackColor = extColor.withAlphaComponent(0.2)
        progressNode.progressColor = extColor

        // Bubble layout
        bubbleNode.layoutSpecBlock = { [weak self] _, constrainedSize in
            guard let self else { return ASLayoutSpec() }

            let maxWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio

            // Icon with extension label centered
            let extCenter = ASCenterLayoutSpec(
                centeringOptions: .XY,
                sizingOptions: .minimumXY,
                child: self.extensionTextNode
            )
            let iconWithLabel = ASOverlayLayoutSpec(
                child: self.iconBackgroundNode,
                overlay: extCenter
            )

            // Progress overlay on icon
            let iconWithProgress = ASOverlayLayoutSpec(
                child: iconWithLabel,
                overlay: self.progressNode
            )

            // Status icon next to time if present
            var timeChildren: [ASLayoutElement] = [self.timeNode]
            if let statusIcon = self.statusIconNode {
                statusIcon.style.preferredSize = CGSize(width: 15, height: 11)
                timeChildren.append(statusIcon)
            }
            let timeRow = ASStackLayoutSpec(
                direction: .horizontal,
                spacing: 3,
                justifyContent: .end,
                alignItems: .center,
                children: timeChildren
            )

            // Size + time row
            let bottomRow = ASStackLayoutSpec(
                direction: .horizontal,
                spacing: 4,
                justifyContent: .spaceBetween,
                alignItems: .center,
                children: [self.sizeNode, timeRow]
            )
            bottomRow.style.width = ASDimension(unit: .fraction, value: 1)

            let rightColumn = ASStackLayoutSpec(
                direction: .vertical,
                spacing: 2,
                justifyContent: .center,
                alignItems: .start,
                children: [self.filenameNode, bottomRow]
            )
            rightColumn.style.flexShrink = 1
            rightColumn.style.flexGrow = 1

            // Main row
            let mainRow = ASStackLayoutSpec(
                direction: .horizontal,
                spacing: 10,
                justifyContent: .start,
                alignItems: .center,
                children: [iconWithProgress, rightColumn]
            )
            mainRow.style.maxWidth = ASDimension(unit: .points, value: maxWidth)

            var contentChildren: [ASLayoutElement] = []

            if let fwd = self.forwardedHeaderNode {
                contentChildren.append(fwd)
            }
            if let replyHeader = self.replyHeaderNode {
                let replyInset = ASInsetLayoutSpec(
                    insets: UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0),
                    child: replyHeader
                )
                contentChildren.append(replyInset)
            }
            contentChildren.append(mainRow)

            let column = ASStackLayoutSpec(
                direction: .vertical,
                spacing: 0,
                justifyContent: .start,
                alignItems: .stretch,
                children: contentChildren
            )

            return ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12),
                child: column
            )
        }

        // Tap handling via ContextSourceNode quick tap
        contextSourceNode.onQuickTap = { [weak self] point in
            guard let self else { return }
            // If the tap lands on reply header, let parent handle it
            if let replyView = self.replyHeaderNode?.view,
               self.isNodeLoaded {
                let replyPoint = self.contextSourceNode.view.convert(point, to: replyView)
                if replyView.bounds.contains(replyPoint) {
                    self.onReplyHeaderTapped?(message.replyInfo?.eventId ?? "")
                    return
                }
            }
            self.onFileTapped?()
        }
    }

    // MARK: - Progress

    func setDownloadState(_ state: DownloadState) {
        self.downloadState = state
    }

    private func updateProgressDisplay() {
        switch downloadState {
        case .idle:
            progressNode.isHidden = true
        case .downloading(let progress):
            progressNode.isHidden = false
            progressNode.progress = progress
        case .downloaded:
            progressNode.isHidden = true
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

    static func formattedSize(_ bytes: UInt64?) -> String {
        guard let bytes else { return "Unknown size" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Circular Progress Node

/// Lightweight circular progress indicator drawn via CAShapeLayer.
/// Runs on GPU, zero per-frame CPU cost.
final class CircularProgressNode: ASDisplayNode {

    var trackColor: UIColor = .systemGray4 {
        didSet { if isNodeLoaded { trackLayer.strokeColor = trackColor.cgColor } }
    }
    var progressColor: UIColor = .systemBlue {
        didSet { if isNodeLoaded { progressLayer.strokeColor = progressColor.cgColor } }
    }
    var lineWidth: CGFloat = 3

    /// 0.0 – 1.0. Negative means indeterminate.
    var progress: Double = 0 {
        didSet { updateProgress() }
    }

    private var trackLayer = CAShapeLayer()
    private var progressLayer = CAShapeLayer()

    override func didLoad() {
        super.didLoad()

        trackLayer.fillColor = nil
        trackLayer.strokeColor = trackColor.cgColor
        trackLayer.lineWidth = lineWidth
        trackLayer.lineCap = .round

        progressLayer.fillColor = nil
        progressLayer.strokeColor = progressColor.cgColor
        progressLayer.lineWidth = lineWidth
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0

        layer.addSublayer(trackLayer)
        layer.addSublayer(progressLayer)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 4
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = UIBezierPath(
            arcCenter: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        ).cgPath
        trackLayer.path = path
        trackLayer.frame = bounds
        progressLayer.path = path
        progressLayer.frame = bounds
    }

    private func updateProgress() {
        guard isNodeLoaded else { return }
        if progress < 0 {
            // Indeterminate — spin
            progressLayer.strokeEnd = 0.25
            if progressLayer.animation(forKey: "spin") == nil {
                let anim = CABasicAnimation(keyPath: "transform.rotation.z")
                anim.fromValue = 0
                anim.toValue = Double.pi * 2
                anim.duration = 1
                anim.repeatCount = .infinity
                progressLayer.add(anim, forKey: "spin")
            }
        } else {
            progressLayer.removeAnimation(forKey: "spin")
            progressLayer.transform = CATransform3DIdentity
            progressLayer.strokeEnd = CGFloat(min(max(progress, 0), 1))
        }
    }
}
