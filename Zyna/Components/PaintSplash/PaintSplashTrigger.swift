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
        overlayView preferredOverlayView: UIView? = nil,
        at indexPath: IndexPath,
        completion: @escaping () -> Void
    ) {
        guard let cellNode = tableNode.nodeForRow(at: indexPath) as? MessageCellNode,
              cellNode.isNodeLoaded
        else {
            completion()
            return
        }
        guard let target = cellNode.paintSplashTarget() else {
            completion()
            return
        }
        trigger(in: tableNode, overlayView: preferredOverlayView, target: target, completion: completion)
    }

    static func trigger(
        in tableNode: ASTableNode,
        overlayView preferredOverlayView: UIView? = nil,
        target: SnapshotTarget,
        completion: @escaping () -> Void
    ) {
        guard target.image.cgImage != nil else {
            completion()
            return
        }

        let overlayView = preferredOverlayView ?? tableNode.view.superview ?? tableNode.view
        let screenSpace = overlayView.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
        let splashFrame = overlayView.convert(target.frameInScreen, from: screenSpace)

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
                if let existing = activeSplashLayer,
                   existing.superlayer === overlayView.layer {
                    splashLayer = existing
                } else {
                    activeSplashLayer?.removeFromSuperlayer()
                    splashLayer = PaintSplashLayer()
                    splashLayer.frame = CGRect(origin: .zero, size: overlayView.bounds.size)
                    splashLayer.zPosition = 10
                    overlayView.layer.addSublayer(splashLayer)
                    activeSplashLayer = splashLayer
                }

                splashLayer.overlayHostView = overlayView
                splashLayer.frame = CGRect(origin: .zero, size: overlayView.bounds.size)
                let screenScale = overlayView.window?.screen.scale ?? UIScreen.main.scale
                splashLayer.drawableSize = CGSize(
                    width: overlayView.bounds.width * screenScale,
                    height: overlayView.bounds.height * screenScale
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
