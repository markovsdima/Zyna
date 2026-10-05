// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

/// A 44-point touch target around the track. Horizontal gestures begun
/// here seek; vertical gestures still scroll the collection.
final class RoomProfileVoiceSeekNode: ASDisplayNode, UIGestureRecognizerDelegate {
    var onSeek: ((Float) -> Void)?
    var onPreview: ((Float) -> Void)?
    var onScrubbing: ((Bool) -> Void)?
    private let track = CALayer()
    private let fill = CALayer()
    private let thumb = CALayer()
    private(set) var progress: Float = 0
    private(set) var isScrubbing = false
    private var pan: UIPanGestureRecognizer?
    private var tap: UITapGestureRecognizer?
    private var initialProgress: Float = 0
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { endScrubbing(cancelled: true) }
            isUserInteractionEnabled = isEnabled
            pan?.isEnabled = isEnabled
            tap?.isEnabled = isEnabled
            if isNodeLoaded { updateLayers() }
        }
    }

    override func didLoad() {
        super.didLoad()
        track.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15).cgColor
        fill.backgroundColor = UIColor.systemBlue.cgColor
        thumb.backgroundColor = UIColor.systemBlue.cgColor
        layer.addSublayer(track)
        layer.addSublayer(fill)
        layer.addSublayer(thumb)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        self.pan = pan
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
        self.tap = tap
        isUserInteractionEnabled = isEnabled
        pan.isEnabled = isEnabled
        tap.isEnabled = isEnabled
        updateLayers()
    }

    override func layout() { super.layout(); updateLayers() }

    func setProgress(_ value: Float) {
        guard !isScrubbing else { return }
        progress = max(0, min(1, value))
        if isNodeLoaded { updateLayers() }
    }

    func endScrubbing(cancelled: Bool = false) {
        guard isScrubbing else { return }
        isScrubbing = false
        if cancelled {
            progress = initialProgress
            updateLayers()
            onPreview?(progress)
        }
        onScrubbing?(false)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan || gestureRecognizer === tap else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard isEnabled else { return false }
        guard gestureRecognizer === pan, let pan else { return true }
        return Self.isSeeking(velocity: pan.velocity(in: view))
    }

    static func isSeeking(velocity: CGPoint) -> Bool {
        return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled && gestureRecognizer === pan && otherGestureRecognizer is UIPanGestureRecognizer
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard isEnabled else { return }
        seek(at: gesture.location(in: view).x, commit: true)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard isEnabled else { return }
        switch gesture.state {
        case .began:
            initialProgress = progress
            isScrubbing = true
            onScrubbing?(true)
            seek(at: gesture.location(in: view).x, commit: false)
        case .changed: seek(at: gesture.location(in: view).x, commit: false)
        case .ended:
            seek(at: gesture.location(in: view).x, commit: true)
            endScrubbing()
        case .cancelled, .failed: endScrubbing(cancelled: true)
        default: break
        }
    }

    private func seek(at x: CGFloat, commit: Bool) {
        progress = Float(max(0, min(1, (x - 6) / max(1, bounds.width - 12))))
        updateLayers()
        onPreview?(progress)
        if commit { onSeek?(progress) }
    }

    private func updateLayers() {
        let height: CGFloat = isEnabled ? 4 : 3
        let width = max(0, bounds.width - 12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 6, y: (bounds.height - height) / 2, width: width, height: height)
        track.cornerRadius = height / 2
        fill.frame = CGRect(x: 6, y: track.frame.minY, width: width * CGFloat(progress), height: height)
        fill.cornerRadius = height / 2
        thumb.frame = CGRect(x: fill.frame.maxX - 5, y: bounds.midY - 5, width: 10, height: 10)
        thumb.cornerRadius = 5
        thumb.isHidden = !isEnabled
        CATransaction.commit()
    }
}
