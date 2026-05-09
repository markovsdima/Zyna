//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

private final class VoicePlayerProgressTouchView: UIView {

    var progressProvider: (() -> CGFloat)?
    var onAdjust: ((CGFloat) -> Void)?

    override var accessibilityValue: String? {
        get {
            let value = Int(((progressProvider?() ?? 0) * 100).rounded())
            return "\(value)%"
        }
        set { }
    }

    override func accessibilityIncrement() {
        adjust(by: 0.05)
    }

    override func accessibilityDecrement() {
        adjust(by: -0.05)
    }

    private func adjust(by delta: CGFloat) {
        let current = progressProvider?() ?? 0
        onAdjust?(min(max(current + delta, 0), 1))
    }
}

final class VoiceTopPlayerView: UIView {

    var onPlayPause: (() -> Void)?
    var onClose: (() -> Void)?
    var onSeek: ((Float) -> Void)?
    var onSpeed: (() -> Void)?

    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    private let tintView = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let timeLabel = UILabel()
    private let progressTrackView = UIView()
    private let progressFillView = UIView()
    private let progressTouchView = VoicePlayerProgressTouchView()

    private var progress: CGFloat = 0 {
        didSet {
            guard abs(progress - oldValue) > 0.0001 else { return }
            updateProgressFillFrame()
        }
    }
    private var isScrubbing = false
    private var scrubProgress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if !playPauseButton.isHidden {
                elements.append(playPauseButton)
            }
            if !(titleLabel.text ?? "").isEmpty {
                elements.append(titleLabel)
            }
            if !(subtitleLabel.text ?? "").isEmpty {
                elements.append(subtitleLabel)
            }
            if !(timeLabel.text ?? "").isEmpty {
                elements.append(timeLabel)
            }
            if progressTouchView.isUserInteractionEnabled {
                elements.append(progressTouchView)
            }
            if !speedButton.isHidden {
                elements.append(speedButton)
            }
            if !closeButton.isHidden {
                elements.append(closeButton)
            }
            return elements
        }
        set { }
    }

    func configure(
        state: AudioPlayerService.State,
        item: AudioPlayerService.NowPlayingItem?,
        snapshot: AudioPlayerService.PlaybackSnapshot
    ) {
        let oldTitleText = titleLabel.text
        let oldSubtitleText = subtitleLabel.text
        let oldTimeText = timeLabel.text

        titleLabel.text = item?.title ?? String(localized: "Voice message")

        let stateText: String?
        switch state {
        case .idle:
            stateText = nil
        case .loading:
            stateText = item?.subtitle ?? String(localized: "Voice message")
        case .playing:
            stateText = item?.subtitle ?? String(localized: "Voice message")
        case .paused:
            let voiceLabel = String(localized: "Voice Message")
            if let subtitle = item?.subtitle, !subtitle.isEmpty {
                stateText = voiceLabel + " - " + subtitle
            } else {
                stateText = voiceLabel
            }
        }
        subtitleLabel.text = stateText

        let normalizedProgress = CGFloat(max(0, min(snapshot.progress, 1)))
        if !isScrubbing {
            progress = normalizedProgress
        }

        if case .loading = state {
            timeLabel.text = String(localized: "Loading")
            playPauseButton.isHidden = true
            speedButton.isEnabled = false
            progressTouchView.isUserInteractionEnabled = false
            spinner.isHidden = false
            spinner.startAnimating()
        } else {
            let displayedProgress = isScrubbing ? scrubProgress : progress
            let remaining = max(0, snapshot.duration * TimeInterval(1 - displayedProgress))
            timeLabel.text = MediaDurationFormatter.shortString(for: remaining)
            playPauseButton.isHidden = false
            speedButton.isEnabled = true
            progressTouchView.isUserInteractionEnabled = snapshot.duration > 0
            spinner.stopAnimating()
            spinner.isHidden = true
        }
        let playbackRateTitle = Self.rateTitle(snapshot.playbackRate)
        speedButton.setTitle(playbackRateTitle, for: .normal)
        speedButton.accessibilityValue = Self.rateAccessibilityValue(snapshot.playbackRate)

        let isPlaying = state.isPlaying
        playPauseButton.setImage(
            (isPlaying ? AppIcon.pause : AppIcon.play).template(size: 15, weight: .semibold),
            for: .normal
        )
        playPauseButton.accessibilityLabel = isPlaying
            ? String(localized: "Pause voice message")
            : String(localized: "Play voice message")

        if oldTitleText != titleLabel.text
            || oldSubtitleText != subtitleLabel.text
            || oldTimeText != timeLabel.text
            || bounds.isEmpty
        {
            setNeedsLayout()
        } else {
            updateProgressFillFrame()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let radius = min(bounds.height / 2, 24)
        effectView.frame = bounds
        effectView.layer.cornerRadius = radius
        tintView.frame = bounds
        layer.cornerRadius = radius

        let buttonSize: CGFloat = 36
        let closeSize: CGFloat = 32
        let horizontalInset: CGFloat = 10
        let centerY = bounds.midY

        playPauseButton.frame = CGRect(
            x: horizontalInset,
            y: centerY - buttonSize / 2,
            width: buttonSize,
            height: buttonSize
        )
        playPauseButton.layer.cornerRadius = buttonSize / 2
        spinner.center = playPauseButton.center

        closeButton.frame = CGRect(
            x: bounds.width - horizontalInset - closeSize,
            y: centerY - closeSize / 2,
            width: closeSize,
            height: closeSize
        )
        closeButton.layer.cornerRadius = closeSize / 2

        let speedSize = CGSize(width: 42, height: 28)
        speedButton.frame = CGRect(
            x: closeButton.frame.minX - 8 - speedSize.width,
            y: centerY - speedSize.height / 2,
            width: speedSize.width,
            height: speedSize.height
        )
        speedButton.layer.cornerRadius = speedSize.height / 2

        let textX = playPauseButton.frame.maxX + 10
        let textRight = speedButton.frame.minX - 8
        let timeSize = timeLabel.sizeThatFits(CGSize(width: 76, height: 18))
        let timeWidth = min(max(timeSize.width, 42), 76)
        timeLabel.frame = CGRect(
            x: textRight - timeWidth,
            y: 10,
            width: timeWidth,
            height: 18
        )

        let titleRight = timeLabel.frame.minX - 8
        let textWidth = max(0, titleRight - textX)
        titleLabel.frame = CGRect(x: textX, y: 8, width: textWidth, height: 19)
        subtitleLabel.frame = CGRect(x: textX, y: 27, width: max(0, textRight - textX), height: 17)

        let progressX = textX
        let progressWidth = max(0, textRight - progressX)
        progressTrackView.frame = CGRect(
            x: progressX,
            y: bounds.height - 8,
            width: progressWidth,
            height: 2
        )
        progressTrackView.layer.cornerRadius = 1
        progressFillView.frame = CGRect(
            x: 0,
            y: 0,
            width: progressWidth * (isScrubbing ? scrubProgress : progress),
            height: progressTrackView.bounds.height
        )
        progressFillView.layer.cornerRadius = 1
        progressTouchView.frame = progressTrackView.frame.insetBy(dx: 0, dy: -7)
    }

    private func updateProgressFillFrame() {
        guard !progressTrackView.bounds.isEmpty else { return }
        let displayedProgress = max(0, min(isScrubbing ? scrubProgress : progress, 1))
        var frame = progressFillView.frame
        frame.origin = .zero
        frame.size.width = progressTrackView.bounds.width * displayedProgress
        frame.size.height = progressTrackView.bounds.height
        progressFillView.frame = frame
    }

    private func setup() {
        isOpaque = false
        clipsToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 8)

        effectView.clipsToBounds = true
        addSubview(effectView)

        tintView.backgroundColor = UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(white: 0.06, alpha: 0.58)
            }
            return UIColor(white: 1.0, alpha: 0.46)
        }
        effectView.contentView.addSubview(tintView)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isAccessibilityElement = true
        effectView.contentView.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isAccessibilityElement = true
        effectView.contentView.addSubview(subtitleLabel)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .secondaryLabel
        timeLabel.textAlignment = .right
        timeLabel.adjustsFontSizeToFitWidth = true
        timeLabel.minimumScaleFactor = 0.75
        timeLabel.isAccessibilityElement = true
        effectView.contentView.addSubview(timeLabel)

        progressTrackView.backgroundColor = UIColor.label.withAlphaComponent(0.14)
        progressTrackView.clipsToBounds = true
        effectView.contentView.addSubview(progressTrackView)

        progressFillView.backgroundColor = AppColor.accent
        progressTrackView.addSubview(progressFillView)

        progressTouchView.backgroundColor = .clear
        progressTouchView.isAccessibilityElement = true
        progressTouchView.accessibilityLabel = String(localized: "Seek voice message")
        progressTouchView.accessibilityTraits = .adjustable
        progressTouchView.progressProvider = { [weak self] in
            guard let self else { return 0 }
            return self.isScrubbing ? self.scrubProgress : self.progress
        }
        progressTouchView.onAdjust = { [weak self] nextProgress in
            guard let self else { return }
            self.scrubProgress = nextProgress
            self.progress = nextProgress
            self.setNeedsLayout()
            self.onSeek?(Float(nextProgress))
        }
        effectView.contentView.addSubview(progressTouchView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(progressTapped(_:)))
        progressTouchView.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(progressPanned(_:)))
        progressTouchView.addGestureRecognizer(pan)

        playPauseButton.tintColor = AppColor.accent
        playPauseButton.backgroundColor = AppColor.accent.withAlphaComponent(0.12)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        playPauseButton.accessibilityTraits = .button
        effectView.contentView.addSubview(playPauseButton)

        speedButton.tintColor = AppColor.accent
        speedButton.backgroundColor = AppColor.accent.withAlphaComponent(0.1)
        speedButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        speedButton.accessibilityLabel = String(localized: "Playback speed")
        speedButton.accessibilityTraits = .button
        speedButton.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        effectView.contentView.addSubview(speedButton)

        closeButton.tintColor = .secondaryLabel
        closeButton.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        closeButton.setImage(AppIcon.xmark.template(size: 12, weight: .semibold), for: .normal)
        closeButton.accessibilityLabel = String(localized: "Close voice player")
        closeButton.accessibilityTraits = .button
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        effectView.contentView.addSubview(closeButton)

        spinner.color = AppColor.accent
        spinner.hidesWhenStopped = true
        effectView.contentView.addSubview(spinner)
    }

    @objc private func playPauseTapped() {
        onPlayPause?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func speedTapped() {
        onSpeed?()
    }

    @objc private func progressTapped(_ gesture: UITapGestureRecognizer) {
        updateScrubProgress(from: gesture.location(in: progressTouchView), commit: true)
        progress = scrubProgress
        setNeedsLayout()
    }

    @objc private func progressPanned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isScrubbing = true
            scrubProgress = progress
            updateScrubProgress(from: gesture.location(in: progressTouchView), commit: true)
        case .changed:
            updateScrubProgress(from: gesture.location(in: progressTouchView), commit: true)
        case .ended, .cancelled, .failed:
            updateScrubProgress(from: gesture.location(in: progressTouchView), commit: true)
            isScrubbing = false
            progress = scrubProgress
        default:
            break
        }
    }

    private func updateScrubProgress(from point: CGPoint, commit: Bool) {
        let width = max(progressTouchView.bounds.width, 1)
        scrubProgress = max(0, min(point.x / width, 1))
        setNeedsLayout()
        if commit {
            onSeek?(Float(scrubProgress))
        }
    }

    private static func rateTitle(_ rate: Float) -> String {
        if abs(rate.rounded() - rate) < 0.01 {
            return String(format: "%.0fx", rate)
        }
        return String(format: "%.1fx", rate)
    }

    private static func rateAccessibilityValue(_ rate: Float) -> String {
        if abs(rate.rounded() - rate) < 0.01 {
            return String(format: "%.0f x", rate)
        }
        return rateTitle(rate)
    }
}
