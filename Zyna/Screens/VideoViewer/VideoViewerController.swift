//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVKit
import UIKit

/// Fullscreen native video viewer with the same lightweight
/// swipe-down dismissal shape as the image viewer. Playback controls
/// remain Apple's `AVPlayerViewController`; this wrapper only owns the
/// presentation chrome and interactive dismissal.
final class VideoViewerController: UIViewController, UIGestureRecognizerDelegate {

    // MARK: - Public

    var onDismissed: (() -> Void)?

    // MARK: - Private

    private let previewImage: UIImage?
    private let sourceFrame: CGRect
    private let aspectRatio: CGFloat?
    private let player: AVPlayer
    private let playerController = AVPlayerViewController()
    private let transitionView = UIImageView()
    private let closeButton = UIButton(type: .system)

    private var didFinishPresentation = false
    private var isDraggingToDismiss = false
    private var isDismissing = false
    private var dismissPanStart: CGPoint = .zero

    // MARK: - Init

    init(
        url: URL,
        previewImage: UIImage?,
        sourceFrame: CGRect,
        aspectRatio: CGFloat?
    ) {
        self.previewImage = previewImage
        self.sourceFrame = sourceFrame
        self.aspectRatio = aspectRatio
        self.player = AVPlayer(url: url)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        playerController.player = player
        playerController.videoGravity = .resizeAspect
        playerController.showsPlaybackControls = true
        addChild(playerController)
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)
        playerController.view.isHidden = true
        playerController.view.backgroundColor = .clear

        transitionView.image = previewImage
        transitionView.backgroundColor = .black
        transitionView.contentMode = .scaleAspectFill
        transitionView.clipsToBounds = true

        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        closeButton.layer.cornerRadius = 22
        closeButton.alpha = 0
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCloseButton()
        guard didFinishPresentation, !isDraggingToDismiss, !isDismissing else { return }
        playerController.view.frame = fittedVideoFrame()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    // MARK: - Presentation

    func animateIn() {
        view.layoutIfNeeded()
        let targetFrame = fittedVideoFrame()

        playerController.view.isHidden = true
        transitionView.frame = sourceFrame == .zero ? targetFrame : sourceFrame
        transitionView.layer.cornerRadius = sourceFrame == .zero ? 0 : 18
        view.addSubview(transitionView)
        view.bringSubviewToFront(closeButton)

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut]
        ) {
            self.transitionView.frame = targetFrame
            self.transitionView.layer.cornerRadius = 0
            self.view.backgroundColor = .black
            self.closeButton.alpha = 1
        } completion: { _ in
            self.transitionView.removeFromSuperview()
            self.playerController.view.frame = targetFrame
            self.playerController.view.isHidden = false
            self.didFinishPresentation = true
            self.player.play()
        }
    }

    // MARK: - Layout

    private func layoutCloseButton() {
        closeButton.frame = CGRect(
            x: 8,
            y: view.safeAreaInsets.top + 4,
            width: 44,
            height: 44
        )
    }

    private func fittedVideoFrame() -> CGRect {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return bounds }

        let ratio = resolvedAspectRatio()
        let fitSize: CGSize
        if ratio > bounds.width / bounds.height {
            fitSize = CGSize(width: bounds.width, height: bounds.width / ratio)
        } else {
            fitSize = CGSize(width: bounds.height * ratio, height: bounds.height)
        }

        return CGRect(
            x: (bounds.width - fitSize.width) / 2,
            y: (bounds.height - fitSize.height) / 2,
            width: fitSize.width,
            height: fitSize.height
        )
    }

    private func resolvedAspectRatio() -> CGFloat {
        if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
            return aspectRatio
        }
        if let previewImage,
           previewImage.size.width > 0,
           previewImage.size.height > 0 {
            return previewImage.size.width / previewImage.size.height
        }
        return 16.0 / 9.0
    }

    // MARK: - Gestures

    @objc private func closeTapped() {
        animateDismiss()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard didFinishPresentation, !isDismissing else { return }

        let translation = gesture.translation(in: view)
        let progress = abs(translation.y) / max(1, view.bounds.height / 2)

        switch gesture.state {
        case .began:
            isDraggingToDismiss = true
            dismissPanStart = playerController.view.center
            closeButton.alpha = 0

        case .changed:
            playerController.view.center = CGPoint(
                x: dismissPanStart.x + translation.x,
                y: dismissPanStart.y + translation.y
            )
            view.backgroundColor = UIColor.black.withAlphaComponent(max(0, 1 - progress))

        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if progress > 0.25 || abs(velocity) > 800 {
                animateDismiss()
            } else {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    usingSpringWithDamping: 0.9,
                    initialSpringVelocity: 0
                ) {
                    self.playerController.view.frame = self.fittedVideoFrame()
                    self.view.backgroundColor = .black
                    self.closeButton.alpha = 1
                } completion: { _ in
                    self.isDraggingToDismiss = false
                }
            }

        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }

    // MARK: - Dismiss

    private func animateDismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        player.pause()
        closeButton.alpha = 0

        let currentFrame = playerController.view.frame
        let transitionContainer = UIView(frame: currentFrame)
        transitionContainer.clipsToBounds = true
        transitionContainer.backgroundColor = .black

        let playerSnapshot = playerController.view.snapshotView(afterScreenUpdates: false)
            ?? UIImageView(image: previewImage)
        playerSnapshot.frame = transitionContainer.bounds
        playerSnapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        transitionContainer.addSubview(playerSnapshot)

        let previewView = UIImageView(image: previewImage)
        previewView.frame = transitionContainer.bounds
        previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        previewView.contentMode = .scaleAspectFill
        previewView.clipsToBounds = true
        previewView.alpha = 0
        transitionContainer.addSubview(previewView)

        playerController.view.isHidden = true
        view.addSubview(transitionContainer)

        let targetFrame = sourceFrame != .zero
            ? sourceFrame
            : CGRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0,
            options: [.curveEaseInOut]
        ) {
            transitionContainer.frame = targetFrame
            transitionContainer.layer.cornerRadius = 18
            previewView.alpha = self.previewImage == nil ? 0 : 1
            playerSnapshot.alpha = self.previewImage == nil ? 1 : 0
            self.view.backgroundColor = .clear
        } completion: { _ in
            self.dismiss(animated: false)
            self.onDismissed?()
        }
    }
}
