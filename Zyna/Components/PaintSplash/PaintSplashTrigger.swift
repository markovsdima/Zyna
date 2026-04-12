//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AsyncDisplayKit

enum PaintSplashTrigger {

    private static weak var activeSplashLayer: PaintSplashLayer?

    static func trigger(
        in tableNode: ASTableNode,
        at indexPath: IndexPath,
        completion: @escaping () -> Void
    ) {
        #if DEBUG
        print("[ZSPLASH-TRIGGER] row=\(indexPath.row)")
        Thread.callStackSymbols.prefix(8).forEach { print("  \($0)") }
        #endif

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

        // Bubble frame in visible table coordinates (subtract contentOffset)
        let contentFrame = bubbleView.convert(bubbleView.bounds, to: tableNode.view)
        let contentOffset = tableNode.view.contentOffset
        let bubbleFrame = contentFrame.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)

        // Phase 1: Anticipation — squash the bubble
        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: .curveEaseIn,
            animations: {
                bubbleView.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
            },
            completion: { _ in
                // Phase 2: Burst — hide cell and start Metal animation
                cellNode.alpha = 0

                let splashLayer: PaintSplashLayer
                if let existing = activeSplashLayer {
                    splashLayer = existing
                } else {
                    splashLayer = PaintSplashLayer()
                    splashLayer.frame = tableNode.view.bounds
                    splashLayer.zPosition = 10
                    tableNode.view.layer.addSublayer(splashLayer)
                    activeSplashLayer = splashLayer
                }

                splashLayer.frame = tableNode.view.bounds
                splashLayer.drawableSize = CGSize(
                    width: tableNode.view.bounds.width * UIScreen.main.scale,
                    height: tableNode.view.bounds.height * UIScreen.main.scale
                )

                splashLayer.addItem(
                    frame: bubbleFrame,
                    image: image
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
