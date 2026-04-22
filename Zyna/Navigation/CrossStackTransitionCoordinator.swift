//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum CrossStackTransitionCoordinator {

    private static let parallaxRatio: CGFloat = 0.3
    private static let dimAlpha: Float = 0.15

    private static func makeBitmapSnapshot(of view: UIView, scale: CGFloat) -> UIView? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }

        let imageView = UIImageView(image: image)
        imageView.frame = view.bounds
        imageView.isOpaque = true
        return imageView
    }

    static func runPushTransition(
        in tabBarController: ZynaTabBarController,
        sourceNavigationController: ZynaNavigationController,
        destinationNavigationController: ZynaNavigationController,
        prepareDestination: () -> Void,
        cleanupSource: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let window = tabBarController.view.window,
              let sourceSnapshot = makeBitmapSnapshot(
                of: tabBarController.view,
                scale: window.screen.scale
              )
        else {
            prepareDestination()
            cleanupSource?()
            completion?()
            return
        }

        let overlay = UIView(frame: tabBarController.view.bounds)
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        tabBarController.view.addSubview(overlay)

        sourceSnapshot.frame = overlay.bounds
        sourceSnapshot.isUserInteractionEnabled = false
        overlay.addSubview(sourceSnapshot)

        GlassService.shared.captureFor(duration: IOS26Spring.duration + 0.1)
        GlassService.shared.setNeedsCapture()

        prepareDestination()

        tabBarController.view.setNeedsLayout()
        tabBarController.view.layoutIfNeeded()
        destinationNavigationController.view.setNeedsLayout()
        destinationNavigationController.view.layoutIfNeeded()

        let dimView = UIView(frame: overlay.bounds)
        dimView.backgroundColor = .black
        dimView.layer.opacity = 0
        dimView.isUserInteractionEnabled = false
        overlay.addSubview(dimView)

        let width = overlay.bounds.width
        let parallax = -(width * parallaxRatio)
        let destinationView = destinationNavigationController.view!
        let savedClips = destinationView.clipsToBounds
        let savedRadius = destinationView.layer.cornerRadius
        let sourcePositionX = sourceSnapshot.layer.position.x

        DispatchQueue.main.async {
            destinationView.removeFromSuperview()
            destinationView.frame = overlay.bounds
            overlay.addSubview(destinationView)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            destinationView.layer.transform = CATransform3DMakeTranslation(width, 0, 0)
            destinationView.layer.cornerRadius = IOS26Spring.screenCornerRadius
            destinationView.layer.cornerCurve = .continuous
            destinationView.clipsToBounds = true
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sourceSnapshot.layer.position.x = sourcePositionX + parallax
            dimView.layer.opacity = dimAlpha
            destinationView.layer.transform = CATransform3DIdentity
            CATransaction.commit()

            CATransaction.begin()
            CATransaction.setCompletionBlock {
                destinationView.layer.cornerRadius = savedRadius
                destinationView.layer.cornerCurve = .circular
                destinationView.clipsToBounds = savedClips
                destinationView.removeFromSuperview()
                tabBarController.reattachSelectedControllerViewIfNeeded()
                overlay.removeFromSuperview()
                cleanupSource?()
                completion?()
            }

            sourceSnapshot.layer.add(
                IOS26Spring.makeAnimation(
                    keyPath: "position.x",
                    from: sourcePositionX,
                    to: sourcePositionX + parallax
                ),
                forKey: "crossStack.parallax"
            )
            dimView.layer.add(
                IOS26Spring.makeAnimation(
                    keyPath: "opacity",
                    from: 0,
                    to: dimAlpha
                ),
                forKey: "crossStack.dim"
            )
            destinationView.layer.add(
                IOS26Spring.makeAnimation(
                    keyPath: "transform.translation.x",
                    from: width,
                    to: 0
                ),
                forKey: "crossStack.slideIn"
            )

            CATransaction.commit()
        }
    }
}
