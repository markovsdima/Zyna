// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import Combine

struct RoomProfileVoicePresentation: Equatable {
    enum Phase: Equatable { case idle, loading, playing, paused, failed(String) }
    var phase: Phase = .idle
    var progress: Float = 0
    var rate: Float = 1
    var duration: TimeInterval?
    var controlsEnabled: Bool { phase == .playing || phase == .paused }

    static func make(item: AttachmentItem, roomID: String, state: AudioPlayerService.State,
                     nowPlaying: AudioPlayerService.NowPlayingItem?,
                     failure: AudioPlayerService.PlaybackFailure?, rate: Float = 1, duration: TimeInterval? = nil) -> Self {
        if let failure, failure.sourceURL == item.sourceMxc,
           failure.eventId == nil || failure.eventId == item.id {
            return Self(phase: .failed(failure.message))
        }
        guard state.sourceURL == item.sourceMxc,
              nowPlaying?.eventId == nil || nowPlaying?.eventId == item.id,
              nowPlaying?.roomId == nil || nowPlaying?.roomId == roomID else { return Self() }
        if case .track? = nowPlaying { return Self() }
        switch state {
        case .idle: return Self()
        case .loading: return Self(phase: .loading)
        case .playing: return Self(phase: .playing, progress: max(0, min(1, state.progress)), rate: rate, duration: duration)
        case .paused: return Self(phase: .paused, progress: max(0, min(1, state.progress)), rate: rate, duration: duration)
        }
    }

    var actionLabel: String {
        switch phase {
        case .loading: return String(localized: "Cancel voice message download")
        case .playing: return String(localized: "Pause voice message")
        case .failed: return String(localized: "Retry voice message")
        case .idle, .paused: return String(localized: "Play voice message")
        }
    }
}

/// One subscription for the active page, with weak references to visible
/// cells only. Playback ticks never rebuild or diff the attachment catalog.
@MainActor
final class RoomProfileVoicePlayback {
    private let player: AudioPlayerService
    private let roomID: String
    private let session: RoomProfileVoiceSession
    private let cells = NSHashTable<RoomProfileVoiceCell>.weakObjects()
    private var subscription: AnyCancellable?
    private(set) var currentEventID: String?
    var onCurrentEventChanged: (() -> Void)?
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            subscription = nil
            if isActive {
                subscription = player.$snapshot.combineLatest(player.$nowPlaying, player.$failure)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] snapshot, item, failure in
                        guard let self, self.isActive else { return }
                        self.apply(snapshot: snapshot, item: item, failure: failure)
                    }
            }
            apply(snapshot: player.snapshot, item: player.nowPlaying, failure: player.failure)
        }
    }

    init(player: AudioPlayerService, roomID: String, session: RoomProfileVoiceSession? = nil) {
        self.player = player
        self.roomID = roomID
        self.session = session ?? RoomProfileVoiceSession()
    }

    func setVisible(_ visible: Bool, cell: RoomProfileVoiceCell) {
        if visible {
            cells.add(cell)
            cell.onSeek = { [weak self, weak cell] progress in
                guard let self, let cell, self.canControl(cell) else { return }
                self.player.seek(to: progress)
            }
            cell.onSpeed = { [weak self, weak cell] in
                guard let self, let cell, self.canControl(cell) else { return }
                self.player.cyclePlaybackRate()
                self.refresh(cell, snapshot: self.player.snapshot, item: self.player.nowPlaying, failure: self.player.failure)
            }
            cell.onStop = { [weak self, weak cell] in
                guard let self, let cell, self.canControl(cell) else { return }
                self.session.remember(eventID: cell.item.id, progress: self.player.snapshot.progress)
                self.player.stop()
                self.apply(snapshot: self.player.snapshot, item: nil, failure: nil)
            }
            refresh(cell, snapshot: player.snapshot, item: player.nowPlaying, failure: player.failure)
        } else {
            cells.remove(cell)
            cell.setPlaybackAnimationEnabled(false)
        }
    }

    private func canControl(_ cell: RoomProfileVoiceCell) -> Bool {
        guard isActive else { return false }
        return RoomProfileVoicePresentation.make(item: cell.item, roomID: roomID, state: player.state,
            nowPlaying: player.nowPlaying, failure: player.failure).controlsEnabled
    }

    private func apply(snapshot: AudioPlayerService.PlaybackSnapshot, item: AudioPlayerService.NowPlayingItem?,
                       failure: AudioPlayerService.PlaybackFailure?) {
        // Failed downloads return to ordinary rows with Retry. Only an
        // active download or player needs to remain in the viewport.
        let eventID = item?.roomId == roomID && item?.sourceURL == snapshot.sourceURL ? item?.eventId : nil
        if currentEventID != eventID {
            currentEventID = eventID
            onCurrentEventChanged?()
        }
        for cell in cells.allObjects { refresh(cell, snapshot: snapshot, item: item, failure: failure) }
    }

    private func refresh(_ cell: RoomProfileVoiceCell, snapshot: AudioPlayerService.PlaybackSnapshot,
                         item: AudioPlayerService.NowPlayingItem?, failure: AudioPlayerService.PlaybackFailure?) {
        let state: AudioPlayerService.State
        if let url = snapshot.sourceURL {
            state = snapshot.isLoading ? .loading(sourceURL: url)
                : (snapshot.isPlaying ? .playing(sourceURL: url, progress: snapshot.progress)
                    : .paused(sourceURL: url, progress: snapshot.progress))
        } else { state = .idle }
        cell.apply(.make(item: cell.item, roomID: roomID, state: state, nowPlaying: item, failure: failure,
            rate: snapshot.playbackRate, duration: snapshot.duration > 0 ? snapshot.duration : nil))
        cell.setPlaybackAnimationEnabled(isActive)
    }
}

/// Texture text/images with a compositor-backed progress bar. Only the
/// duration's displayed second and discrete playback states redraw text.
final class RoomProfileVoiceCell: ASCellNode {
    struct Images {
        let play: UIImage
        let pause: UIImage
        let cancel: UIImage
        let retry: UIImage
        // Initialize on main before Texture starts creating nodes.
        init() {
            play = AppIcon.play.template(size: 17)
            pause = AppIcon.pause.template(size: 17)
            cancel = AppIcon.xmark.template(size: 15)
            retry = AppIcon.play.template(size: 17)
        }
    }

    let item: AttachmentItem
    var onVisibilityChanged: ((Bool) -> Void)?
    var onAccessibilityChanged: ((String, String) -> Void)?
    private let images: Images
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let dateNode = ASTextNode()
    private let totalDurationNode = ASTextNode()
    private let durationNode = ASTextNode()
    private let iconNode = ASImageNode()
    let seekNode = RoomProfileVoiceSeekNode()
    private let speedNode = ASButtonNode()
    private let stopNode = ASButtonNode()
    private let controlsNode = ASDisplayNode()
    private let idleHeader: RoomProfileVoiceFadeNode
    private let playingHeader: RoomProfileVoiceFadeNode
    private let idleMetadata: RoomProfileVoiceFadeNode
    private let playingMetadata: RoomProfileVoiceFadeNode
    private let dockBackdrop = ASDisplayNode()
    private let dockSeparator = ASDisplayNode()
    private(set) var dockEdge: RoomProfileListAttributes.DockEdge = .none
    var onSeek: ((Float) -> Void)?
    var onSpeed: (() -> Void)?
    var onStop: (() -> Void)?
    var onControlsChanged: ((Bool) -> Void)?
    var onScrubbing: ((Bool) -> Void)?
    var controlsEnabled: Bool { presentation.controlsEnabled }
    var rateTitle: String { String(format: "%g×", presentation.rate) }
    private let loadingRing = CAShapeLayer()
    private let normalSubtitle: String
    private var presentation = RoomProfileVoicePresentation()
    private var totalDurationText: String?
    private var animationEnabled = false

    init(item: AttachmentItem, title: String, subtitle: String, images: Images) {
        self.item = item
        self.images = images
        normalSubtitle = subtitle
        idleHeader = RoomProfileVoiceFadeNode(content: totalDurationNode, initiallyVisible: true)
        playingHeader = RoomProfileVoiceFadeNode(content: dateNode, initiallyVisible: false)
        idleMetadata = RoomProfileVoiceFadeNode(content: subtitleNode, initiallyVisible: true)
        playingMetadata = RoomProfileVoiceFadeNode(content: controlsNode, initiallyVisible: false)
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .appBG
        dockBackdrop.isLayerBacked = true
        dockBackdrop.backgroundColor = Self.dockedBackground
        dockBackdrop.alpha = 0
        dockSeparator.isLayerBacked = true
        dockSeparator.backgroundColor = .separator
        dockSeparator.alpha = 0
        iconNode.isLayerBacked = true
        iconNode.image = images.play
        iconNode.tintColor = .systemBlue
        iconNode.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        iconNode.contentMode = .center
        iconNode.cornerRadius = 22
        iconNode.style.preferredSize = CGSize(width: 44, height: 44)
        seekNode.isAccessibilityElement = false
        seekNode.isUserInteractionEnabled = false
        speedNode.isAccessibilityElement = false
        speedNode.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        speedNode.cornerRadius = 14
        speedNode.isUserInteractionEnabled = false
        stopNode.setImage(images.cancel, for: .normal)
        stopNode.imageNode.tintColor = .secondaryLabel
        stopNode.isAccessibilityElement = false
        stopNode.isUserInteractionEnabled = false
        controlsNode.automaticallyManagesSubnodes = true
        controlsNode.layoutSpecBlock = { [durationNode, seekNode, speedNode, stopNode] _, _ in
            ASAbsoluteLayoutSpec(children: [durationNode, seekNode, speedNode, stopNode])
        }
        for node in [idleHeader, playingHeader, idleMetadata] {
            node.isLayerBacked = true
            node.content.isLayerBacked = true
            node.isUserInteractionEnabled = false
        }
        playingMetadata.isUserInteractionEnabled = false
        seekNode.onPreview = { [weak self] progress in
            guard let self, self.controlsEnabled else { return }
            self.presentation.progress = progress
            self.updateDuration()
        }
        seekNode.onSeek = { [weak self] in self?.onSeek?($0) }
        seekNode.onScrubbing = { [weak self] in self?.onScrubbing?($0) }
        titleNode.maximumNumberOfLines = 1
        subtitleNode.maximumNumberOfLines = 2
        dateNode.maximumNumberOfLines = 1
        totalDurationNode.maximumNumberOfLines = 1
        durationNode.maximumNumberOfLines = 1
        titleNode.attributedText = text(title, style: .body, color: .label)
        subtitleNode.attributedText = text(subtitle, style: .caption1, color: .secondaryLabel)
        dateNode.attributedText = text(subtitle, style: .caption1, color: .secondaryLabel)
        speedNode.setAttributedTitle(text(rateTitle, style: .subheadline, color: .systemBlue, compact: true), for: .normal)
        updateDuration()
        accessibilityLabel = String(localized: "Voice message") + ", " + title + ", " + subtitle
    }

    override func didLoad() {
        super.didLoad()
        speedNode.addTarget(self, action: #selector(changeSpeed), forControlEvents: .touchUpInside)
        stopNode.addTarget(self, action: #selector(stopPlayback), forControlEvents: .touchUpInside)
        loadingRing.fillColor = UIColor.clear.cgColor
        loadingRing.strokeColor = UIColor.systemBlue.cgColor
        loadingRing.lineWidth = 2
        loadingRing.lineCap = .round
        loadingRing.strokeStart = 0.08
        loadingRing.strokeEnd = 0.78
        iconNode.layer.addSublayer(loadingRing)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeAnimation),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        updateLoadingAnimation()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private static func font(_ style: UIFont.TextStyle, compact: Bool = false) -> UIFont {
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: .current)
        return compact ? font.withSize(min(font.pointSize, 24)) : font
    }

    private static var durationWidth: CGFloat {
        max(44, ("0:00:00" as NSString).size(withAttributes: [.font: font(.caption1, compact: true)]).width.rounded(.up))
    }

    private static var speedWidth: CGFloat {
        max(44, ("0.5×" as NSString).size(withAttributes: [.font: font(.subheadline, compact: true)]).width.rounded(.up) + 16)
    }

    static func rowHeight(width: CGFloat) -> CGFloat {
        let regular = UIFontMetrics.default.scaledValue(for: 92, compatibleWith: .current)
        let stacked = width - 88 - durationWidth - speedWidth - 44 - 18 < 64
        let required = 4 + font(.body).lineHeight + 2 + font(.caption1).lineHeight + 2 + (stacked ? 88 : 44) + 4
        return max(regular, required)
    }

    override func didEnterVisibleState() {
        super.didEnterVisibleState()
        onVisibilityChanged?(true)
    }

    override func didExitVisibleState() {
        super.didExitVisibleState()
        onVisibilityChanged?(false)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let width = constrainedSize.max.width
        let height = Self.rowHeight(width: width)
        let titleHeight = Self.font(.body).lineHeight
        let captionHeight = Self.font(.caption1).lineHeight
        let timeHeight = Self.font(.caption1, compact: true).lineHeight
        let textX: CGFloat = 72
        let subtitleWidth = max(1, width - textX - 16)
        let dateSize = CGSize(width: min(subtitleWidth, ceil(dateNode.attributedText?.size().width ?? 0)), height: captionHeight)
        let subtitleHeight = subtitleNode.attributedText?.boundingRect(
            with: CGSize(width: subtitleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height ?? captionHeight
        let subtitleSize = CGSize(width: subtitleWidth, height: min(captionHeight * 2, ceil(subtitleHeight)))
        let titleWidth = titleNode.attributedText?.size().width ?? 0
        let dateFitsBesideTitle = dateSize.width + 8
            + min(titleWidth, UIFontMetrics.default.scaledValue(for: 110)) <= subtitleWidth
        let durationWidth = Self.durationWidth
        let speedWidth = Self.speedWidth
        let controlHeight: CGFloat = 44
        let trackWidth = subtitleWidth - durationWidth - speedWidth - 44 - 18
        let stackedControls = trackWidth < 64
        let buttonsY = height - controlHeight - 4
        let trackY = stackedControls ? buttonsY - 44 : buttonsY
        // All frames are independent of playback. Only content opacity
        // changes, including when the controls need a second line.
        let titleY: CGFloat = dateFitsBesideTitle
            ? max(4, min((height - titleHeight - 4 - captionHeight) / 2, trackY - titleHeight - 4)) : 4
        func place(_ node: ASDisplayNode, _ rect: CGRect) {
            node.style.layoutPosition = rect.origin
            node.style.preferredSize = rect.size
        }
        place(iconNode, CGRect(x: 16, y: (height - 44) / 2, width: 44, height: 44))
        let nameWidth = subtitleWidth - (dateFitsBesideTitle ? max(dateSize.width, durationWidth) : durationWidth) - 8
        place(titleNode, CGRect(x: textX, y: titleY, width: max(1, nameWidth), height: titleHeight))
        place(idleHeader, CGRect(x: width - 16 - durationWidth,
            y: titleY + (titleHeight - timeHeight) / 2, width: durationWidth, height: timeHeight))
        if dateFitsBesideTitle {
            place(playingHeader, CGRect(x: width - 16 - dateSize.width,
                y: titleY + (titleHeight - captionHeight) / 2, width: max(1, dateSize.width), height: captionHeight))
        } else {
            place(playingHeader, CGRect(x: textX, y: titleY + 2 + titleHeight,
                width: subtitleWidth, height: captionHeight))
        }
        let metadataHeight = height - 4 - trackY
        place(idleMetadata, CGRect(x: textX, y: trackY + max(0, (metadataHeight - subtitleSize.height) / 2),
            width: subtitleWidth, height: min(metadataHeight, subtitleSize.height)))
        place(playingMetadata, CGRect(x: textX, y: trackY, width: subtitleWidth, height: metadataHeight))
        let controlsY = buttonsY - trackY
        place(durationNode, CGRect(x: 0, y: controlsY + (controlHeight - timeHeight) / 2,
            width: durationWidth, height: timeHeight))
        place(seekNode, CGRect(x: stackedControls ? 0 : durationWidth + 6,
            y: 0, width: stackedControls ? subtitleWidth : max(1, trackWidth), height: 44))
        place(speedNode, CGRect(x: subtitleWidth - 44 - 6 - speedWidth, y: controlsY,
            width: speedWidth, height: controlHeight))
        place(stopNode, CGRect(x: subtitleWidth - 44, y: controlsY, width: 44, height: controlHeight))
        place(dockBackdrop, CGRect(x: 0, y: 0, width: width, height: height))
        place(dockSeparator, CGRect(x: 0, y: dockEdge == .top ? height - 0.5 : 0, width: width, height: 0.5))
        return ASAbsoluteLayoutSpec(children: [dockBackdrop, dockSeparator, iconNode, titleNode,
            idleHeader, playingHeader, idleMetadata, playingMetadata])
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loadingRing.frame = iconNode.bounds
        loadingRing.path = UIBezierPath(ovalIn: iconNode.bounds.insetBy(dx: 2, dy: 2)).cgPath
        CATransaction.commit()
    }

    func containsControl(at point: CGPoint) -> Bool {
        controlsEnabled && [seekNode, speedNode, stopNode].contains { node in
            node.bounds.contains(node.convert(point, from: self))
        }
    }

    func adjustPlayback(forward: Bool) {
        guard controlsEnabled else { return }
        let value = max(0, min(1, presentation.progress + (forward ? 0.05 : -0.05)))
        presentation.progress = value
        seekNode.setProgress(value)
        updateDuration()
        onSeek?(value)
    }

    @objc func changeSpeed() {
        guard controlsEnabled else { return }
        onSpeed?()
    }

    @objc func stopPlayback() {
        guard controlsEnabled else { return }
        onStop?()
    }

    static let dockedBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.06, alpha: 1) : UIColor(white: 0.98, alpha: 1)
    }

    func setDockEdge(_ edge: RoomProfileListAttributes.DockEdge) {
        guard dockEdge != edge else { return }
        dockEdge = edge
        let nodes = [dockBackdrop, dockSeparator]
        let starts = isNodeLoaded ? nodes.map { ($0.layer.presentation() ?? $0.layer).opacity } : []
        for node in nodes { node.alpha = edge == .none ? 0 : 1 }
        setNeedsLayout()
        guard isNodeLoaded else { return }
        layoutIfNeeded()
        for (index, node) in nodes.enumerated() {
            node.layer.removeAnimation(forKey: "voiceDock.opacity")
            if animationEnabled, !UIAccessibility.isReduceMotionEnabled, starts[index] != node.layer.opacity {
                node.layer.add(IOS26Spring.makeAnimation(keyPath: "opacity", from: starts[index], to: node.layer.opacity),
                    forKey: "voiceDock.opacity")
            }
        }
    }

    func apply(_ value: RoomProfileVoicePresentation) {
        var value = value
        if seekNode.isScrubbing, value.controlsEnabled { value.progress = seekNode.progress }
        guard value != presentation else { return }
        let old = presentation
        let controlsChanged = old.controlsEnabled != value.controlsEnabled
        presentation = value
        if old.phase != value.phase {
            let subtitle: String
            let failed: Bool
            switch value.phase {
            case .loading: iconNode.image = images.cancel; subtitle = String(localized: "Loading"); failed = false
            case .playing: iconNode.image = images.pause; subtitle = normalSubtitle; failed = false
            case .failed(let message): iconNode.image = images.retry; subtitle = message; failed = true
            case .idle, .paused: iconNode.image = images.play; subtitle = normalSubtitle; failed = false
            }
            iconNode.tintColor = failed ? .systemRed : .systemBlue
            // Keep outgoing idle text intact until its fade completes.
            // Loading/errors replace the date only in the idle state.
            if !value.controlsEnabled {
                subtitleNode.attributedText = text(subtitle, style: .caption1, color: failed ? .systemRed : .secondaryLabel)
                setNeedsLayout()
            }
            updateLoadingAnimation()
        }
        if controlsChanged {
            seekNode.isEnabled = value.controlsEnabled
            speedNode.isUserInteractionEnabled = value.controlsEnabled
            stopNode.isUserInteractionEnabled = value.controlsEnabled
            playingMetadata.isUserInteractionEnabled = value.controlsEnabled
            onControlsChanged?(value.controlsEnabled)
            setNeedsLayout()
        }
        if value.controlsEnabled, old.rate != value.rate || controlsChanged {
            speedNode.setAttributedTitle(text(rateTitle, style: .subheadline, color: .systemBlue, compact: true), for: .normal)
        }
        updateDuration()
        if value.controlsEnabled { seekNode.setProgress(value.progress) }
        if controlsChanged {
            if isNodeLoaded { layoutIfNeeded() }
            idleHeader.setShowing(!value.controlsEnabled, animated: animationEnabled)
            idleMetadata.setShowing(!value.controlsEnabled, animated: animationEnabled)
            playingHeader.setShowing(value.controlsEnabled, animated: animationEnabled)
            playingMetadata.setShowing(value.controlsEnabled, animated: animationEnabled)
        }
    }

    func setPlaybackAnimationEnabled(_ enabled: Bool) {
        guard animationEnabled != enabled else { return }
        animationEnabled = enabled
        if !enabled {
            seekNode.endScrubbing(cancelled: true)
            for content in metadataStates { content.finishAnimations() }
            if isNodeLoaded {
                dockBackdrop.layer.removeAnimation(forKey: "voiceDock.opacity")
                dockSeparator.layer.removeAnimation(forKey: "voiceDock.opacity")
            }
        }
        updateLoadingAnimation()
    }

    private var metadataStates: [RoomProfileVoiceFadeNode] {
        [idleHeader, playingHeader, idleMetadata, playingMetadata]
    }

    private func updateDuration() {
        let duration = presentation.duration ?? item.durationSeconds ?? 0
        let totalFormatted = MediaDurationFormatter.shortString(for: duration)
        if totalDurationText != totalFormatted {
            totalDurationText = totalFormatted
            totalDurationNode.attributedText = text(totalFormatted, style: .caption1, color: .secondaryLabel, compact: true)
        }
        let remaining = duration * Double(1 - presentation.progress)
        let formatted = MediaDurationFormatter.shortString(for: remaining)
        // The retiring player keeps its last time during the fade.
        if (controlsEnabled || durationNode.attributedText == nil), durationNode.attributedText?.string != formatted {
            durationNode.attributedText = text(formatted, style: .caption1, color: .secondaryLabel, compact: true)
            setNeedsLayout()
        }
        let value: String
        switch presentation.phase {
        case .loading: value = String(localized: "Loading")
        case .failed(let message): value = message
        default: value = controlsEnabled ? formatted + ", " + rateTitle : formatted
        }
        if accessibilityValue != value || accessibilityHint != presentation.actionLabel {
            accessibilityValue = value
            accessibilityHint = presentation.actionLabel
            onAccessibilityChanged?(value, presentation.actionLabel)
        }
    }

    @objc private func resumeAnimation() { updateLoadingAnimation() }

    private func updateLoadingAnimation() {
        guard isNodeLoaded else { return }
        let loading = presentation.phase == .loading
        loadingRing.isHidden = !loading
        guard loading && animationEnabled && !UIAccessibility.isReduceMotionEnabled else {
            loadingRing.removeAnimation(forKey: "loading")
            return
        }
        guard loadingRing.animation(forKey: "loading") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.toValue = CGFloat.pi * 2
        animation.duration = 0.9
        animation.repeatCount = .infinity
        loadingRing.add(animation, forKey: "loading")
    }

    private func text(_ value: String, style: UIFont.TextStyle, color: UIColor, compact: Bool = false) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [.font: Self.font(style, compact: compact), .foregroundColor: color])
    }
}
