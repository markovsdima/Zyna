// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

struct RoomProfileVoiceTabPlayback: Equatable {
    let sourceURL: String
    let eventID: String?
    let progress: Float
    let isPlaying: Bool
    let duration: TimeInterval
    let playbackRate: Float

    static func make(roomID: String, snapshot: AudioPlayerService.PlaybackSnapshot,
                     item: AudioPlayerService.NowPlayingItem?) -> Self? {
        guard case .voice(let voice) = item, voice.roomId == roomID,
              snapshot.sourceURL == voice.sourceURL, !snapshot.isLoading,
              snapshot.progress.isFinite else { return nil }
        return Self(sourceURL: voice.sourceURL, eventID: voice.eventId,
            progress: max(0, min(1, snapshot.progress)), isPlaying: snapshot.isPlaying,
            duration: snapshot.duration, playbackRate: snapshot.playbackRate)
    }
}

/// Small header control: paging moves one layer, playback scales another.
/// Neither operation rebuilds labels or participates in list layout.
final class RoomProfileTabsView: UIView {
    var onSelect: ((Int) -> Void)?
    var isEnabled = true {
        didSet { buttons.forEach { $0.isEnabled = isEnabled } }
    }
    private(set) var selectedIndex = 0
    private(set) var position: CGFloat = 0
    private(set) var voicePlayback: RoomProfileVoiceTabPlayback?
    var numberOfTabs: Int { buttons.count }

    private let selection = CALayer()
    private let voiceTrack = CALayer()
    private let voiceFill = CALayer()
    private var buttons: [UIButton] = []
    private var titleWidths: [CGFloat] = []
    private var voiceIndex: Int?
    private var spokenPercent: Int?
    private var spokenIsPlaying: Bool?
    private var playbackAnimationEnabled = false
    private var progressMotion: (playback: RoomProfileVoiceTabPlayback, start: CFTimeInterval)?
    private static let progressAnimationKey = "profile.voiceTab.progress"

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityTraits = .tabBar
        selection.name = "profile.tabs.selection"
        voiceTrack.name = "profile.tabs.voice"
        voiceFill.name = "profile.tabs.voice.fill"
        selection.shadowOpacity = 0.08
        selection.shadowRadius = 2
        selection.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(selection)
        layer.addSublayer(voiceTrack)
        voiceTrack.masksToBounds = true
        voiceTrack.addSublayer(voiceFill)
        voiceTrack.isHidden = true
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (view: RoomProfileTabsView, _) in view.updateColors()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self]) {
            (view: RoomProfileTabsView, _) in
            view.updateFonts()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateVoiceAnimation()
    }

    func setPlaybackAnimationEnabled(_ enabled: Bool) {
        guard playbackAnimationEnabled != enabled else { return }
        playbackAnimationEnabled = enabled
        updateVoiceAnimation()
    }

    func setTabs(_ titles: [String], selectedIndex: Int, voiceIndex: Int?) {
        while buttons.count > titles.count { buttons.removeLast().removeFromSuperview() }
        for (index, title) in titles.enumerated() {
            if index == buttons.count {
                let button = UIButton(type: .custom)
                button.tag = index
                button.isEnabled = isEnabled
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.75
                button.titleLabel?.lineBreakMode = .byTruncatingTail
                button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
                addSubview(button)
                buttons.append(button)
            }
            buttons[index].setTitle(title, for: .normal)
            buttons[index].accessibilityValue = nil
        }
        self.voiceIndex = voiceIndex
        accessibilityElements = buttons
        spokenPercent = nil
        spokenIsPlaying = nil
        updateFonts()
        updateColors()
        setSelectedIndex(selectedIndex)
        updateAccessibilityProgress()
        updateVoiceAnimation()
        setNeedsLayout()
    }

    func setSelectedIndex(_ index: Int) {
        selectedIndex = max(0, min(buttons.count - 1, index))
        for (index, button) in buttons.enumerated() {
            button.accessibilityTraits = index == selectedIndex ? [.button, .selected] : .button
        }
        setPosition(CGFloat(selectedIndex))
    }

    func setPosition(_ value: CGFloat) {
        guard value.isFinite else { return }
        let next = max(0, min(CGFloat(max(0, buttons.count - 1)), value))
        guard position != next else { return }
        position = next
        layoutSelection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !buttons.isEmpty else { return }
        let area = bounds.insetBy(dx: 3, dy: 3)
        let minimum = min(44, max(0, area.width) / CGFloat(buttons.count))
        let weights = titleWidths.map { max(1, $0 + 20 - minimum) }
        let totalWeight = weights.reduce(0, +)
        let extra = max(0, area.width - minimum * CGFloat(buttons.count))
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var x = area.minX
        for (index, button) in buttons.enumerated() {
            let width = minimum + extra * weights[index] / totalWeight
            let origin = rtl ? bounds.maxX - x - width : x
            button.frame = CGRect(x: origin, y: bounds.minY, width: width, height: bounds.height)
            x += width
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = bounds.height / 2
        if let index = voiceIndex, buttons.indices.contains(index),
           buttons[index].bounds.width > 2, buttons[index].bounds.height > 6 {
            voiceTrack.frame = capsuleFrame(at: index)
            voiceTrack.cornerRadius = voiceTrack.bounds.height / 2
            voiceFill.anchorPoint = CGPoint(x: rtl ? 1 : 0, y: 0.5)
            voiceFill.bounds = CGRect(origin: .zero, size: voiceTrack.bounds.size)
            voiceFill.position = CGPoint(x: rtl ? voiceTrack.bounds.width : 0, y: voiceTrack.bounds.midY)
            voiceTrack.isHidden = voicePlayback == nil
        } else { voiceTrack.isHidden = true }
        CATransaction.commit()
        layoutSelection()
    }

    private func capsuleFrame(at index: Int) -> CGRect { buttons[index].frame.insetBy(dx: 1, dy: 3) }

    private func layoutSelection() {
        guard !buttons.isEmpty else { selection.isHidden = true; return }
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        guard buttons[lower].bounds.width > 2, buttons[lower].bounds.height > 6 else {
            selection.isHidden = true
            return
        }
        let start = capsuleFrame(at: lower), end = capsuleFrame(at: upper)
        let fraction = position - CGFloat(lower)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.isHidden = false
        let previousBounds = selection.bounds
        selection.frame = CGRect(x: start.minX + (end.minX - start.minX) * fraction, y: start.minY,
            width: start.width + (end.width - start.width) * fraction, height: start.height)
        selection.cornerRadius = selection.bounds.height / 2
        if selection.shadowPath == nil || selection.bounds != previousBounds {
            selection.shadowPath = UIBezierPath(roundedRect: selection.bounds,
                cornerRadius: selection.cornerRadius).cgPath
        }
        CATransaction.commit()
    }

    func setVoicePlayback(_ playback: RoomProfileVoiceTabPlayback?) {
        guard playback != voicePlayback else { return }
        let old = voicePlayback
        voicePlayback = playback
        let progress = CGFloat(playback?.progress ?? 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        voiceTrack.isHidden = playback == nil || voiceIndex == nil
        voiceFill.transform = CATransform3DMakeScale(progress, 1, 1)
        CATransaction.commit()
        if old?.isPlaying != playback?.isPlaying { updateColors() }
        if let old, let playback, playback.progress < old.progress {
            stopVoiceAnimation()
        }
        updateVoiceAnimation()
        updateAccessibilityProgress()
    }

    private func updateVoiceAnimation() {
        guard playbackAnimationEnabled, window != nil, !UIAccessibility.isReduceMotionEnabled,
              let index = voiceIndex, buttons.indices.contains(index),
              let playback = voicePlayback, playback.isPlaying, playback.progress < 1,
              playback.duration.isFinite, playback.duration > 0,
              playback.playbackRate.isFinite, playback.playbackRate > 0 else {
            stopVoiceAnimation()
            return
        }
        let now = voiceFill.convertTime(CACurrentMediaTime(), from: nil)
        if let motion = progressMotion,
           motion.playback.sourceURL == playback.sourceURL, motion.playback.eventID == playback.eventID,
           motion.playback.duration == playback.duration, motion.playback.playbackRate == playback.playbackRate {
            let expected = min(1, Double(motion.playback.progress)
                + (now - motion.start) * Double(playback.playbackRate) / playback.duration)
            // Let Core Animation advance uniformly between audio samples.
            // Resync only for a seek/drift, allowing for sample delivery jitter.
            if abs(expected - Double(playback.progress)) * playback.duration < 0.1,
               voiceFill.animation(forKey: Self.progressAnimationKey) != nil { return }
        }
        let animation = CABasicAnimation(keyPath: "transform.scale.x")
        animation.fromValue = CGFloat(playback.progress)
        animation.toValue = CGFloat(1)
        animation.beginTime = now
        animation.duration = (1 - Double(playback.progress)) * playback.duration / Double(playback.playbackRate)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        // Slow, sustained progress should not request ProMotion by itself.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        voiceFill.add(animation, forKey: Self.progressAnimationKey)
        progressMotion = (playback, now)
    }

    private func stopVoiceAnimation() {
        guard progressMotion != nil else { return }
        voiceFill.removeAnimation(forKey: Self.progressAnimationKey)
        progressMotion = nil
    }

    private func updateAccessibilityProgress() {
        guard let index = voiceIndex, buttons.indices.contains(index) else { return }
        guard let playback = voicePlayback else {
            buttons[index].accessibilityValue = nil
            spokenPercent = nil
            spokenIsPlaying = nil
            return
        }
        let percent = Int((playback.progress * 100).rounded())
        guard spokenPercent != percent || spokenIsPlaying != playback.isPlaying else { return }
        spokenPercent = percent
        spokenIsPlaying = playback.isPlaying
        let formatted = (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
        let format = playback.isPlaying ? String(localized: "Playing: %@", table: "RoomProfile")
            : String(localized: "Paused: %@", table: "RoomProfile")
        buttons[index].accessibilityValue = String(format: format, formatted)
    }

    @objc private func tapped(_ button: UIButton) {
        guard isEnabled else { return }
        onSelect?(button.tag)
    }

    private func updateFonts() {
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 13, weight: .medium), maximumPointSize: 20, compatibleWith: traitCollection)
        buttons.forEach { $0.titleLabel?.font = font }
        // Measure only when titles or typography change, not while paging.
        titleWidths = buttons.map { (($0.title(for: .normal) ?? "") as NSString).size(withAttributes: [.font: font]).width }
    }

    private func updateColors() {
        backgroundColor = .tertiarySystemFill
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.backgroundColor = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traitCollection).cgColor
        voiceTrack.backgroundColor = UIColor.systemBlue.resolvedColor(with: traitCollection).withAlphaComponent(0.05).cgColor
        voiceFill.backgroundColor = UIColor.systemBlue.resolvedColor(with: traitCollection)
            .withAlphaComponent(voicePlayback?.isPlaying == true ? 0.24 : 0.17).cgColor
        CATransaction.commit()
        for button in buttons {
            button.setTitleColor(.label, for: .normal)
            button.setTitleColor(.tertiaryLabel, for: .disabled)
        }
    }
}
