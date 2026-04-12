//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import MatrixRustSDK

/// Fullscreen image viewer with zoom, pan, and interactive
/// swipe-down dismiss. Shows the cached thumbnail immediately
/// and swaps in the full-resolution image when it loads.
///
/// Transition uses a dedicated `transitionView` (aspectFill +
/// clipsToBounds) that animates between the cell's cropped frame
/// and the fullscreen fitted frame. The same view handles both
/// entrance and dismissal so the crop matches the cell exactly.
final class ImageViewerController: UIViewController {

    // MARK: - Public

    let imageView = UIImageView()
    let scrollView = UIScrollView()

    /// Source frame in window coordinates — where the image flies
    /// from on present and back to on dismiss.
    var sourceFrame: CGRect = .zero

    var onDismissed: (() -> Void)?

    // MARK: - Private

    private let transitionView = UIImageView()
    private let mediaSource: MediaSource?
    private var dismissPanStart: CGPoint = .zero

    // MARK: - Init

    init(image: UIImage, mediaSource: MediaSource?) {
        self.mediaSource = mediaSource
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
        transitionView.image = image
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true

        // transitionView is used only during enter/exit animation
        transitionView.contentMode = .scaleAspectFill
        transitionView.clipsToBounds = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        loadFullResolution()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        layoutImageView()
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Transition In

    func animateIn(from frame: CGRect) {
        scrollView.isHidden = true
        imageView.isHidden = true
        view.backgroundColor = .clear

        // transitionView starts at the cell's exact position
        transitionView.frame = frame
        transitionView.layer.cornerRadius = 18
        view.addSubview(transitionView)

        // Target: aspect-fit frame in screen
        let targetFrame = fittedImageFrame()

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
        } completion: { _ in
            self.transitionView.removeFromSuperview()
            self.imageView.isHidden = false
            self.scrollView.isHidden = false
            self.scrollView.addSubview(self.imageView)
            self.layoutImageView()
        }
    }

    // MARK: - Layout

    private func fittedImageFrame() -> CGRect {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0
        else { return view.bounds }

        let bounds = view.bounds
        let ratio = image.size.width / image.size.height
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

    private func layoutImageView() {
        let frame = fittedImageFrame()
        imageView.frame = frame
        scrollView.contentSize = frame.size
    }

    // MARK: - Full resolution

    private func loadFullResolution() {
        guard let source = mediaSource else { return }
        Task {
            guard let client = MatrixClientService.shared.client else { return }
            do {
                let data = try await client.getMediaContent(mediaSource: source)
                guard let fullImage = UIImage(data: data) else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.imageView.image = fullImage
                    self.layoutImageView()
                }
            } catch {
                // Thumbnail stays visible — full-res is optional.
            }
        }
    }

    // MARK: - Gestures

    @objc private func handleTap() {
        animateDismiss()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let zoomRect = CGRect(
                x: point.x - 50, y: point.y - 50,
                width: 100, height: 100
            )
            scrollView.zoom(to: zoomRect, animated: true)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard scrollView.zoomScale <= 1 else { return }

        let translation = gesture.translation(in: view)
        let progress = abs(translation.y) / (view.bounds.height / 2)

        switch gesture.state {
        case .began:
            dismissPanStart = imageView.center

        case .changed:
            imageView.center = CGPoint(
                x: dismissPanStart.x + translation.x,
                y: dismissPanStart.y + translation.y
            )
            view.backgroundColor = UIColor.black.withAlphaComponent(max(0, 1 - progress))

        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            if progress > 0.25 || abs(velocity) > 800 {
                animateDismiss()
            } else {
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                    self.imageView.center = self.dismissPanStart
                    self.view.backgroundColor = .black
                }
            }

        default:
            break
        }
    }

    // MARK: - Dismiss

    private func animateDismiss() {
        scrollView.setZoomScale(1, animated: false)

        // Move image out of scroll view for free positioning
        let currentFrame = imageView.convert(imageView.bounds, to: view)
        imageView.removeFromSuperview()
        view.addSubview(imageView)
        imageView.frame = currentFrame

        // Use transitionView for the "fly back" with aspectFill crop
        transitionView.frame = currentFrame
        transitionView.layer.cornerRadius = 0
        transitionView.image = imageView.image
        view.addSubview(transitionView)
        imageView.isHidden = true

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
            self.transitionView.frame = targetFrame
            self.transitionView.layer.cornerRadius = 18
            self.view.backgroundColor = .clear
        } completion: { _ in
            self.dismiss(animated: false)
            self.onDismissed?()
        }
    }
}

// MARK: - UIScrollViewDelegate

extension ImageViewerController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let x = max(0, (boundsSize.width - contentSize.width) / 2)
        let y = max(0, (boundsSize.height - contentSize.height) / 2)
        imageView.frame.origin = CGPoint(x: x, y: y)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ImageViewerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x) && scrollView.zoomScale <= 1
    }
}
