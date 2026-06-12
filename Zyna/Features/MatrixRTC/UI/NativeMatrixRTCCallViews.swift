//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import MatrixRTCLiveKit
import UIKit

final class NativeMatrixRTCCallRootView: UIView {
    var onControlTapped: ((NativeMatrixRTCCallControlKind) -> Void)? {
        didSet {
            controlsBar.onControlTapped = onControlTapped
        }
    }

    private let backgroundView = UIView()
    private let directStageView = NativeMatrixRTCDirectCallStageView()
    private let groupStageView = NativeMatrixRTCGroupCallStageView()
    private let topBar = NativeMatrixRTCCallTopBar()
    private let controlsBar = NativeMatrixRTCCallControlsBar()
    private var controlsCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: NativeMatrixRTCCallViewState) {
        switch state.stage {
        case .direct(let stage):
            backgroundView.backgroundColor = .black
            directStageView.isHidden = false
            groupStageView.isHidden = true
            directStageView.render(stage)
        case .group(let stage):
            backgroundView.backgroundColor = UIColor.dynamic(
                light: UIColor(hex: 0x111318),
                dark: UIColor(hex: 0x050608)
            )
            directStageView.isHidden = true
            groupStageView.isHidden = false
            groupStageView.render(stage)
        }

        topBar.render(state.topBar)
        controlsCount = state.controls.count
        controlsBar.render(state.controls)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        backgroundView.frame = bounds
        directStageView.frame = bounds

        let topInset = safeAreaInsets.top
        let bottomInset = safeAreaInsets.bottom
        let controlsHeight: CGFloat = 88
        let controlsMaxWidth: CGFloat = controlsCount > 5 ? 520 : 430
        let controlsWidth = min(bounds.width - 12, controlsMaxWidth)
        controlsBar.frame = CGRect(
            x: (bounds.width - controlsWidth) / 2,
            y: bounds.height - bottomInset - controlsHeight - 18,
            width: controlsWidth,
            height: controlsHeight
        )

        let topBarWidth = min(bounds.width - 28, 520)
        topBar.frame = CGRect(
            x: (bounds.width - topBarWidth) / 2,
            y: topInset + 12,
            width: topBarWidth,
            height: 58
        )

        let stageTop = topBar.isHidden ? topInset + 18 : topBar.frame.maxY + 14
        let stageBottom = controlsBar.frame.minY - 18
        groupStageView.frame = CGRect(
            x: 12,
            y: stageTop,
            width: bounds.width - 24,
            height: max(0, stageBottom - stageTop)
        )
    }

    private func setup() {
        backgroundColor = .black
        addSubview(backgroundView)
        addSubview(directStageView)
        addSubview(groupStageView)
        addSubview(topBar)
        addSubview(controlsBar)
        controlsBar.onControlTapped = onControlTapped
    }
}

private final class NativeMatrixRTCCallTopBar: UIView {
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let titleLabel = UILabel()
    private let statusStack = UIStackView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: NativeMatrixRTCCallTopBarState?) {
        guard let state else {
            isHidden = true
            return
        }

        isHidden = false
        titleLabel.text = state.title
        statusLabel.text = state.status
        if state.isStatusBusy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        let contentBounds = bounds.insetBy(dx: 16, dy: 7)
        titleLabel.frame = CGRect(
            x: contentBounds.minX,
            y: contentBounds.minY,
            width: contentBounds.width,
            height: 23
        )
        statusStack.frame = CGRect(
            x: contentBounds.minX,
            y: titleLabel.frame.maxY + 1,
            width: contentBounds.width,
            height: 19
        )
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous

        addSubview(blurView)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.numberOfLines = 1
        addSubview(titleLabel)

        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.distribution = .fill
        statusStack.spacing = 6
        statusStack.isUserInteractionEnabled = false
        addSubview(statusStack)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = .white
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.76)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail

        let leadingSpacer = UIView()
        let trailingSpacer = UIView()
        statusStack.addArrangedSubview(leadingSpacer)
        statusStack.addArrangedSubview(activityIndicator)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(trailingSpacer)
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
}

private final class NativeMatrixRTCDirectCallStageView: UIView {
    private let remoteVideoView = MatrixRTCLiveKitVideoView()
    private let audioContainerView = UIView()
    private let avatarView = NativeMatrixRTCAvatarView()
    private let titleLabel = UILabel()
    private let statusStack = UIStackView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let localPreviewView = NativeMatrixRTCParticipantTileView()

    private var state: NativeMatrixRTCDirectCallStageState?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: NativeMatrixRTCDirectCallStageState) {
        self.state = state

        let hasRemoteVideo = state.remoteVideoTrack != nil
        remoteVideoView.isHidden = !hasRemoteVideo
        remoteVideoView.setRemoteVideoTrack(state.remoteVideoTrack)

        audioContainerView.isHidden = hasRemoteVideo
        avatarView.render(state.peer.avatar, diameter: 124)
        titleLabel.text = state.title
        statusLabel.text = state.status
        if state.isStatusBusy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if let localVideoTrack = state.localVideoTrack {
            localPreviewView.isHidden = false
            localPreviewView.render(NativeMatrixRTCParticipantTileState(
                id: "local-preview",
                displayName: String(localized: "You"),
                avatar: AvatarViewModel(
                    userId: "local",
                    displayName: String(localized: "You"),
                    mxcAvatarURL: nil
                ),
                videoTrack: .local(localVideoTrack),
                isAudioMuted: false,
                isHandRaised: false,
                isLocal: true,
                statusText: nil
            ))
        } else {
            localPreviewView.isHidden = true
            localPreviewView.prepareForNoTrack()
        }

        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        remoteVideoView.frame = bounds

        let centerY = bounds.midY - max(28, bounds.height * 0.08)
        let avatarSide: CGFloat = min(132, max(108, bounds.width * 0.32))
        avatarView.frame = CGRect(
            x: (bounds.width - avatarSide) / 2,
            y: centerY - avatarSide / 2 - 58,
            width: avatarSide,
            height: avatarSide
        )
        titleLabel.frame = CGRect(
            x: 28,
            y: avatarView.frame.maxY + 26,
            width: bounds.width - 56,
            height: 38
        )
        statusStack.frame = CGRect(
            x: 28,
            y: titleLabel.frame.maxY + 8,
            width: bounds.width - 56,
            height: 24
        )
        audioContainerView.frame = bounds

        let previewWidth = min(128, max(108, bounds.width * 0.3))
        let previewHeight = previewWidth * 4.0 / 3.0
        localPreviewView.frame = CGRect(
            x: bounds.width - previewWidth - 18,
            y: bounds.height - safeAreaInsets.bottom - previewHeight - 124,
            width: previewWidth,
            height: previewHeight
        )
    }

    private func setup() {
        backgroundColor = .black
        remoteVideoView.backgroundColor = .black
        remoteVideoView.layoutMode = .fill
        addSubview(remoteVideoView)

        audioContainerView.backgroundColor = .clear
        addSubview(audioContainerView)
        audioContainerView.addSubview(avatarView)

        titleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.76
        audioContainerView.addSubview(titleLabel)

        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 7
        audioContainerView.addSubview(statusStack)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = .white
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8

        let leadingSpacer = UIView()
        let trailingSpacer = UIView()
        statusStack.addArrangedSubview(leadingSpacer)
        statusStack.addArrangedSubview(activityIndicator)
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(trailingSpacer)
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        localPreviewView.layer.cornerRadius = 18
        localPreviewView.layer.cornerCurve = .continuous
        localPreviewView.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        localPreviewView.layer.borderWidth = 0.75
        localPreviewView.clipsToBounds = true
        localPreviewView.isHidden = true
        addSubview(localPreviewView)
    }
}

private final class NativeMatrixRTCGroupCallStageView: UIView {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let emptyView = UIView()
    private let emptyAvatarView = NativeMatrixRTCAvatarView()
    private let emptyTitleLabel = UILabel()
    private let emptyStatusLabel = UILabel()

    private var tileViewsByID: [String: NativeMatrixRTCParticipantTileView] = [:]
    private var orderedTileIDs: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: NativeMatrixRTCGroupCallStageState) {
        let nextIDs = state.tiles.map(\.id)
        let nextIDSet = Set(nextIDs)

        for tileID in Array(tileViewsByID.keys) where !nextIDSet.contains(tileID) {
            guard let tileView = tileViewsByID.removeValue(forKey: tileID) else { continue }
            tileView.prepareForNoTrack()
            tileView.removeFromSuperview()
        }

        for tile in state.tiles {
            let tileView = tileViewsByID[tile.id] ?? makeTileView()
            tileView.render(tile)
            tileViewsByID[tile.id] = tileView
        }

        orderedTileIDs = nextIDs
        emptyView.isHidden = !state.tiles.isEmpty
        emptyAvatarView.render(state.room.avatar, diameter: 110)
        emptyTitleLabel.text = state.emptyTitle
        emptyStatusLabel.text = state.emptyStatus
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        layoutEmptyView()
        layoutTiles()
    }

    private func setup() {
        backgroundColor = .clear

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        scrollView.addSubview(contentView)

        addSubview(emptyView)
        emptyView.addSubview(emptyAvatarView)
        emptyView.addSubview(emptyTitleLabel)
        emptyView.addSubview(emptyStatusLabel)

        emptyTitleLabel.font = .systemFont(ofSize: 27, weight: .semibold)
        emptyTitleLabel.textColor = .white
        emptyTitleLabel.textAlignment = .center
        emptyTitleLabel.numberOfLines = 2
        emptyTitleLabel.adjustsFontSizeToFitWidth = true
        emptyTitleLabel.minimumScaleFactor = 0.78

        emptyStatusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyStatusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        emptyStatusLabel.textAlignment = .center
        emptyStatusLabel.numberOfLines = 2
    }

    private func makeTileView() -> NativeMatrixRTCParticipantTileView {
        let tileView = NativeMatrixRTCParticipantTileView()
        tileView.layer.cornerRadius = 18
        tileView.layer.cornerCurve = .continuous
        tileView.clipsToBounds = true
        contentView.addSubview(tileView)
        return tileView
    }

    private func layoutEmptyView() {
        emptyView.frame = bounds
        let avatarSide: CGFloat = min(122, max(96, bounds.width * 0.28))
        emptyAvatarView.frame = CGRect(
            x: (bounds.width - avatarSide) / 2,
            y: max(20, bounds.midY - avatarSide - 52),
            width: avatarSide,
            height: avatarSide
        )
        emptyTitleLabel.frame = CGRect(
            x: 24,
            y: emptyAvatarView.frame.maxY + 24,
            width: bounds.width - 48,
            height: 66
        )
        emptyStatusLabel.frame = CGRect(
            x: 24,
            y: emptyTitleLabel.frame.maxY + 6,
            width: bounds.width - 48,
            height: 46
        )
    }

    private func layoutTiles() {
        guard !orderedTileIDs.isEmpty else {
            contentView.frame = CGRect(origin: .zero, size: bounds.size)
            scrollView.contentSize = bounds.size
            return
        }

        let spacing: CGFloat = 8
        let columns = columnCount(for: orderedTileIDs.count)
        let rows = Int(ceil(Double(orderedTileIDs.count) / Double(columns)))
        let tileWidth = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let minimumTileHeight = minimumTileHeight(for: columns)
        let fittedTileHeight = (bounds.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        let tileHeight = orderedTileIDs.count <= 4
            ? max(minimumTileHeight, fittedTileHeight)
            : max(minimumTileHeight, min(tileWidth * 1.18, fittedTileHeight))
        let contentHeight = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * spacing
        let verticalOffset = max(0, (bounds.height - contentHeight) / 2)

        contentView.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(bounds.height, contentHeight)
        )
        scrollView.contentSize = contentView.bounds.size

        for index in orderedTileIDs.indices {
            guard let tileView = tileViewsByID[orderedTileIDs[index]] else { continue }
            let row = index / columns
            let column = index % columns
            tileView.frame = CGRect(
                x: CGFloat(column) * (tileWidth + spacing),
                y: verticalOffset + CGFloat(row) * (tileHeight + spacing),
                width: tileWidth,
                height: tileHeight
            )
        }
    }

    private func columnCount(for count: Int) -> Int {
        switch count {
        case 0, 1:
            return 1
        case 2:
            return bounds.width >= bounds.height ? 2 : 1
        case 3, 4:
            return 2
        default:
            if bounds.width >= 760 {
                return 4
            }
            return bounds.width > bounds.height ? 3 : 2
        }
    }

    private func minimumTileHeight(for columns: Int) -> CGFloat {
        switch columns {
        case 1:
            return 220
        case 2:
            return 172
        case 3:
            return 150
        default:
            return 132
        }
    }
}

private final class NativeMatrixRTCParticipantTileView: UIView {
    private let videoView = MatrixRTCLiveKitVideoView()
    private let avatarView = NativeMatrixRTCAvatarView()
    private let gradientLayer = CAGradientLayer()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let handBadgeView = UIImageView()
    private let micBadgeView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: NativeMatrixRTCParticipantTileState) {
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        avatarView.render(state.avatar, diameter: 84)
        nameLabel.text = state.displayName
        statusLabel.text = state.statusText
        statusLabel.isHidden = state.statusText == nil
        micBadgeView.isHidden = !state.isAudioMuted
        handBadgeView.isHidden = !state.isHandRaised
        accessibilityLabel = accessibilityLabel(for: state)

        if let videoTrack = state.videoTrack {
            videoView.isHidden = false
            avatarView.isHidden = true
            switch videoTrack {
            case .local(let track):
                videoView.mirrorMode = .auto
                videoView.setLocalVideoTrack(track)
            case .remote(let track):
                videoView.mirrorMode = .off
                videoView.setRemoteVideoTrack(track)
            }
        } else {
            prepareForNoTrack()
            avatarView.isHidden = false
        }

        setNeedsLayout()
    }

    func prepareForNoTrack() {
        videoView.setLocalVideoTrack(nil)
        videoView.setRemoteVideoTrack(nil)
        videoView.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView.frame = bounds
        gradientLayer.frame = bounds

        let avatarSide = min(bounds.width, bounds.height) * 0.28
        let avatarSize = min(max(64, avatarSide), 108)
        avatarView.frame = CGRect(
            x: (bounds.width - avatarSize) / 2,
            y: (bounds.height - avatarSize) / 2 - 18,
            width: avatarSize,
            height: avatarSize
        )

        let labelHeight: CGFloat = 22
        let statusHeight: CGFloat = statusLabel.isHidden ? 0 : 18
        statusLabel.frame = CGRect(
            x: 14,
            y: bounds.height - 14 - statusHeight,
            width: bounds.width - 28,
            height: statusHeight
        )
        nameLabel.frame = CGRect(
            x: 14,
            y: (statusLabel.isHidden ? bounds.height - 16 - labelHeight : statusLabel.frame.minY - labelHeight - 2),
            width: bounds.width - 28,
            height: labelHeight
        )

        let badgeSide: CGFloat = 30
        handBadgeView.frame = CGRect(
            x: 12,
            y: 12,
            width: badgeSide,
            height: badgeSide
        )
        handBadgeView.layer.cornerRadius = badgeSide / 2

        micBadgeView.frame = CGRect(
            x: bounds.width - badgeSide - 12,
            y: 12,
            width: badgeSide,
            height: badgeSide
        )
        micBadgeView.layer.cornerRadius = badgeSide / 2
    }

    private func setup() {
        backgroundColor = UIColor.white.withAlphaComponent(0.08)

        videoView.layoutMode = .fill
        videoView.backgroundColor = .black
        addSubview(videoView)

        addSubview(avatarView)

        gradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.58).cgColor
        ]
        gradientLayer.locations = [0.46, 1.0]
        layer.addSublayer(gradientLayer)

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.numberOfLines = 1
        addSubview(nameLabel)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.74)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.numberOfLines = 1
        addSubview(statusLabel)

        handBadgeView.image = UIImage(
            systemName: "hand.raised.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        handBadgeView.tintColor = .black
        handBadgeView.backgroundColor = .systemYellow
        handBadgeView.contentMode = .center
        handBadgeView.clipsToBounds = true
        addSubview(handBadgeView)

        micBadgeView.image = UIImage(
            systemName: "mic.slash.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        micBadgeView.tintColor = .white
        micBadgeView.backgroundColor = UIColor.black.withAlphaComponent(0.52)
        micBadgeView.contentMode = .center
        micBadgeView.clipsToBounds = true
        addSubview(micBadgeView)
    }

    private func accessibilityLabel(for state: NativeMatrixRTCParticipantTileState) -> String {
        var parts = [state.displayName]
        if state.isLocal {
            parts.append(String(localized: "You"))
        }
        if state.isHandRaised {
            parts.append(String(localized: "Hand Raised"))
        }
        if state.isAudioMuted {
            parts.append(String(localized: "Muted"))
        }
        if let statusText = state.statusText {
            parts.append(statusText)
        }
        return parts.joined(separator: ", ")
    }
}

private final class NativeMatrixRTCAvatarView: UIView {
    private let imageView = UIImageView()
    private var representedAvatarURL: String?
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    func render(_ avatar: AvatarViewModel, diameter: CGFloat) {
        let roundedDiameter = max(1, diameter)
        imageView.image = avatar.circleImage(diameter: roundedDiameter, fontSize: roundedDiameter * 0.34)
        representedAvatarURL = avatar.mxcAvatarURL
        loadTask?.cancel()

        guard let mxc = avatar.mxcAvatarURL else { return }
        loadTask = Task { @MainActor [weak self] in
            let pixelSize = Int(roundedDiameter * UIScreen.main.scale)
            guard let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: pixelSize) else {
                return
            }
            guard self?.representedAvatarURL == mxc else { return }
            self?.imageView.image = image
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        imageView.layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func setup() {
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }
}

private final class NativeMatrixRTCCallControlsBar: UIView {
    var onControlTapped: ((NativeMatrixRTCCallControlKind) -> Void)?

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let stackView = UIStackView()
    private var buttonsByKind: [NativeMatrixRTCCallControlKind: UIButton] = [:]
    private var sizeConstraintsByKind: [NativeMatrixRTCCallControlKind: (width: NSLayoutConstraint, height: NSLayoutConstraint)] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ controls: [NativeMatrixRTCCallControlState]) {
        let nextKinds = Set(controls.map(\.kind))
        for (kind, button) in Array(buttonsByKind) where !nextKinds.contains(kind) {
            button.removeFromSuperview()
            buttonsByKind.removeValue(forKey: kind)
            if let constraints = sizeConstraintsByKind.removeValue(forKey: kind) {
                NSLayoutConstraint.deactivate([constraints.width, constraints.height])
            }
        }

        for control in controls {
            let button = buttonsByKind[control.kind] ?? makeButton(for: control.kind)
            configure(button, with: control)
            if button.superview == nil {
                stackView.addArrangedSubview(button)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        stackView.frame = bounds.insetBy(dx: 12, dy: 12)
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerRadius = 34
        layer.cornerCurve = .continuous
        addSubview(blurView)

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.distribution = .equalSpacing
        stackView.spacing = 7
        addSubview(stackView)
    }

    private func makeButton(for kind: NativeMatrixRTCCallControlKind) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(self, action: #selector(controlTapped(_:)), for: .touchUpInside)
        button.tag = kind.tag
        buttonsByKind[kind] = button
        return button
    }

    private func configure(_ button: UIButton, with control: NativeMatrixRTCCallControlState) {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(
            systemName: control.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .semibold)
        )
        configuration.baseForegroundColor = .white
        configuration.baseBackgroundColor = color(for: control.style)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.accessibilityLabel = control.accessibilityLabel
        button.isEnabled = control.isEnabled
        button.alpha = control.isEnabled ? 1.0 : 0.38
        button.layer.cornerRadius = control.size / 2
        button.clipsToBounds = true

        button.translatesAutoresizingMaskIntoConstraints = false
        if let constraints = sizeConstraintsByKind[control.kind] {
            constraints.width.constant = control.size
            constraints.height.constant = control.size
        } else {
            let width = button.widthAnchor.constraint(equalToConstant: control.size)
            let height = button.heightAnchor.constraint(equalToConstant: control.size)
            NSLayoutConstraint.activate([width, height])
            sizeConstraintsByKind[control.kind] = (width, height)
        }
    }

    private func color(for style: NativeMatrixRTCCallControlStyle) -> UIColor {
        switch style {
        case .neutral:
            return UIColor.white.withAlphaComponent(0.18)
        case .active:
            return AppColor.accent
        case .warning:
            return .systemOrange
        case .destructive:
            return AppColor.destructive
        }
    }

    @objc private func controlTapped(_ sender: UIButton) {
        guard let kind = NativeMatrixRTCCallControlKind(tag: sender.tag) else { return }
        onControlTapped?(kind)
    }
}

private extension NativeMatrixRTCCallControlKind {
    var tag: Int {
        switch self {
        case .microphone: return 1
        case .speaker: return 2
        case .camera: return 3
        case .switchCamera: return 4
        case .raiseHand: return 5
        case .end: return 6
        }
    }

    init?(tag: Int) {
        switch tag {
        case 1: self = .microphone
        case 2: self = .speaker
        case 3: self = .camera
        case 4: self = .switchCamera
        case 5: self = .raiseHand
        case 6: self = .end
        default: return nil
        }
    }
}
