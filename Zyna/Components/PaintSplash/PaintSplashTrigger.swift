//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AsyncDisplayKit

enum PaintSplashTrigger {

    struct SnapshotTarget {
        let sourceView: UIView
        let frameInScreen: CGRect
        let image: UIImage
        let hideSource: () -> Void
    }

    private static weak var activeSplashLayer: PaintSplashLayer?

    static func trigger(
        in tableNode: ASTableNode,
        at indexPath: IndexPath,
        completion: @escaping () -> Void
    ) {
        guard let cellNode = tableNode.nodeForRow(at: indexPath) as? MessageCellNode,
              cellNode.isNodeLoaded
        else {
            completion()
            return
        }

        let bubbleView = cellNode.bubbleNode.view

        guard bubbleView.bounds.width > 0, bubbleView.bounds.height > 0 else {
            completion()
            return
        }

        // Snapshot the bubble via layer rendering (immune to compositing race)
        let image = UIGraphicsImageRenderer(bounds: bubbleView.bounds).image { ctx in
            bubbleView.layer.render(in: ctx.cgContext)
        }

        guard image.cgImage != nil else {
            completion()
            return
        }

        let target = SnapshotTarget(
            sourceView: bubbleView,
            frameInScreen: bubbleView.convert(
                bubbleView.bounds,
                to: bubbleView.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
            ),
            image: image,
            hideSource: { cellNode.alpha = 0 }
        )

        trigger(in: tableNode, target: target, completion: completion)
    }

    static func trigger(
        in tableNode: ASTableNode,
        target: SnapshotTarget,
        completion: @escaping () -> Void
    ) {
        guard target.image.cgImage != nil else {
            completion()
            return
        }

        let screenSpace = tableNode.view.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
        let splashFrame = tableNode.view.convert(target.frameInScreen, from: screenSpace)

        // Phase 1: Anticipation — squash the bubble
        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: .curveEaseIn,
            animations: {
                target.sourceView.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
            },
            completion: { _ in
                target.sourceView.transform = .identity
                // Phase 2: Burst — hide cell and start Metal animation
                target.hideSource()

                let splashLayer: PaintSplashLayer
                if let existing = activeSplashLayer {
                    splashLayer = existing
                } else {
                    splashLayer = PaintSplashLayer()
                    splashLayer.frame = CGRect(origin: .zero, size: tableNode.view.bounds.size)
                    splashLayer.zPosition = 10
                    tableNode.view.layer.addSublayer(splashLayer)
                    activeSplashLayer = splashLayer
                }

                splashLayer.frame = CGRect(origin: .zero, size: tableNode.view.bounds.size)
                splashLayer.drawableSize = CGSize(
                    width: tableNode.view.bounds.width * UIScreen.main.scale,
                    height: tableNode.view.bounds.height * UIScreen.main.scale
                )

                splashLayer.addItem(
                    frame: splashFrame,
                    image: target.image
                )

                // Layer self-cleans when all droplets are done
                splashLayer.becameEmpty = { [weak splashLayer] in
                    splashLayer?.removeFromSuperlayer()
                    activeSplashLayer = nil
                }

                // Collapse the gap immediately
                completion()
            }
        )
    }
}
