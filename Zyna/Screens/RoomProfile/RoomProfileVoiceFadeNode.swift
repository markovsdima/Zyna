// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

/// A permanent metadata state that fades within fixed row geometry.
final class RoomProfileVoiceFadeNode: ASDisplayNode {
    let content: ASDisplayNode
    private(set) var isShowing: Bool

    init(content: ASDisplayNode, initiallyVisible: Bool) {
        self.content = content
        isShowing = initiallyVisible
        super.init()
        automaticallyManagesSubnodes = true
        clipsToBounds = true
        isAccessibilityElement = false
        // ASTextNode marks itself accessible again when its text changes.
        // Only the row is exposed to VoiceOver, including during a fade.
        accessibilityElementsHidden = true
        content.isAccessibilityElement = false
        content.alpha = initiallyVisible ? 1 : 0
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        content.style.preferredSize = constrainedSize.max
        return ASWrapperLayoutSpec(layoutElement: content)
    }

    func setShowing(_ showing: Bool, animated: Bool, reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard showing != isShowing else { return }
        let layer = animated && isNodeLoaded && bounds.width > 0 ? content.layer : nil
        // Reversing before the first render commit has no presentation
        // layer yet; continue from the pending animation's starting value.
        let pending = (layer?.animation(forKey: "voiceContent.opacity") as? CABasicAnimation)?.fromValue as? NSNumber
        let start = layer?.presentation()?.opacity ?? pending?.floatValue ?? Float(content.alpha)
        isShowing = showing
        content.alpha = showing ? 1 : 0
        finishAnimations()
        guard let layer, start != layer.opacity else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start
        fade.toValue = layer.opacity
        fade.duration = reduceMotion ? 0.16 : 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        layer.add(fade, forKey: "voiceContent.opacity")
    }

    func finishAnimations() {
        guard isNodeLoaded else { return }
        content.layer.removeAnimation(forKey: "voiceContent.opacity")
    }
}
