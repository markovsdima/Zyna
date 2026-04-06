//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

/// Compact status indicator composed of shared pre-rendered UIImages
/// (see `MessageStatusIconImages`). The node itself does no custom
/// drawing — each state is simply zero-to-two `ASImageNode`s sized
/// and positioned inside a small square. The only per-frame work is
/// a `CABasicAnimation` on the clock-hand layer, which runs entirely
/// on the GPU compositor.
///
/// New cell nodes created by Texture pay no CPU cost: image contents
/// are shared CGImages across every chat bubble.
final class MessageStatusIconNode: ASDisplayNode {

    // MARK: - Public

    /// Tint colour applied to template images (clock + checks). No
    /// effect on the failed badge, which is authored in full colour.
    var tintColour: UIColor = .secondaryLabel {
        didSet {
            guard tintColour != oldValue else { return }
            applyTintColour()
        }
    }

    /// Current visual state. Assigning rebuilds the subnode set.
    var icon: MessageStatusIcon? = nil {
        didSet {
            guard icon != oldValue else { return }
            rebuildSubnodes()
        }
    }

    /// Icon side length (pt).
    let iconSize: CGFloat

    // MARK: - Subnodes

    private var imageNodes: [ASImageNode] = []
    private var rotatingNode: ASImageNode?

    // MARK: - Init

    init(size: CGFloat = MessageStatusIconConfig.defaultSize) {
        self.iconSize = size
        super.init()
        style.preferredSize = CGSize(width: size * 1.6, height: size)
        automaticallyManagesSubnodes = true
        backgroundColor = .clear
        isOpaque = false
        isLayerBacked = true
    }

    // MARK: - Lifecycle

    override func didLoad() {
        super.didLoad()
        startRotationIfNeeded()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Absolute layout honours the `layoutPosition` we set on each
        // subnode when we build them. Wrapper/stack specs would
        // re-flow them and collapse the overlapping offset.
        return ASAbsoluteLayoutSpec(
            sizing: .sizeToFit,
            children: imageNodes
        )
    }

    // MARK: - Subnode graph

    private func rebuildSubnodes() {
        imageNodes.forEach { $0.removeFromSupernode() }
        imageNodes.removeAll()
        rotatingNode = nil

        guard let icon else {
            setNeedsLayout()
            return
        }

        switch icon {
        case .pending:
            addPendingClockNodes()
        case .sent:
            addCheckNode(offset: 0)
        case .delivered:
            addDoubleCheckNodes()
        case .failed:
            addFailedBadgeNode()
        }

        applyTintColour()
        setNeedsLayout()
        startRotationIfNeeded()
    }

    private func addPendingClockNodes() {
        let frame = makeTemplateImageNode(image: MessageStatusIconImages.clockFrame)
        let hand = makeTemplateImageNode(image: MessageStatusIconImages.clockHand)
        let square = CGSize(width: iconSize, height: iconSize)
        frame.style.preferredSize = square
        frame.style.layoutPosition = .zero
        hand.style.preferredSize = square
        hand.style.layoutPosition = .zero
        imageNodes = [frame, hand]
        rotatingNode = hand
    }

    private func addCheckNode(offset: CGFloat) {
        let image = MessageStatusIconImages.check
        let node = makeTemplateImageNode(image: image)
        node.style.preferredSize = image.size
        node.style.layoutPosition = CGPoint(x: offset, y: 0)
        imageNodes.append(node)
    }

    private func addDoubleCheckNodes() {
        // Two full V-ticks layered with a horizontal offset — the
        // second one lands on top of the first's ascending leg, so
        // they read as one "delivered" glyph.
        let offset = iconSize * MessageStatusIconConfig.doubleCheckOffsetRatio
        addCheckNode(offset: 0)
        addCheckNode(offset: offset)
    }

    private func addFailedBadgeNode() {
        let image = MessageStatusIconImages.failedBadge
        let node = ASImageNode()
        node.image = image
        node.contentMode = .center
        node.isLayerBacked = true
        node.style.preferredSize = image.size
        node.style.layoutPosition = CGPoint(
            x: (iconSize - image.size.width) / 2,
            y: (iconSize - image.size.height) / 2
        )
        imageNodes.append(node)
    }

    private func makeTemplateImageNode(image: UIImage) -> ASImageNode {
        let node = ASImageNode()
        node.image = image
        node.contentMode = .center
        node.isLayerBacked = true
        return node
    }

    // MARK: - Tint

    private func applyTintColour() {
        let cg = tintColour
        for node in imageNodes where node.image?.renderingMode == .alwaysTemplate {
            // imageModificationBlock tints the image at display time
            // without touching the shared CGImage.
            node.imageModificationBlock = ASImageNodeTintColorModificationBlock(cg)
        }
    }

    // MARK: - Rotation

    private static let rotationKey = "clockRotation"

    private func startRotationIfNeeded() {
        guard isNodeLoaded, let rotatingNode else { return }
        guard rotatingNode.layer.animation(forKey: Self.rotationKey) == nil else { return }
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = 2 * CGFloat.pi
        anim.duration = MessageStatusIconConfig.clockRotationPeriod
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        rotatingNode.layer.add(anim, forKey: Self.rotationKey)
    }
}
