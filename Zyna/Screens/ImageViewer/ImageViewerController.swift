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
    private let toolbar = UIView()
    private let closeButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let mediaSource: MediaSource?
    private var dismissPanStart: CGPoint = .zero
    private var chromeVisible = true

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
        view.backgroundColor = .clear

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

        setupChrome()
        loadFullResolution()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        layoutImageView()
        layoutChrome()
        layoutToolbar()
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

    // MARK: - Chrome (close button + toolbar)

    private func setupChrome() {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)

        // Close button
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: config),
            for: .normal
        )
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        // Bottom toolbar
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        shareButton.setImage(
            UIImage(systemName: "square.and.arrow.up", withConfiguration: config),
            for: .normal
        )
        shareButton.tintColor = .white
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        saveButton.setImage(
            UIImage(systemName: "square.and.arrow.down", withConfiguration: config),
            for: .normal
        )
        saveButton.tintColor = .white
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        toolbar.addSubview(shareButton)
        toolbar.addSubview(saveButton)
        view.addSubview(toolbar)
    }

    private func layoutChrome() {
        let safeTop = view.safeAreaInsets.top
        closeButton.frame = CGRect(x: 8, y: safeTop + 4, width: 44, height: 44)
    }

    private func layoutToolbar() {
        let safeBottom = view.safeAreaInsets.bottom
        let barHeight: CGFloat = 44
        let totalHeight = barHeight + safeBottom
        toolbar.frame = CGRect(
            x: 0,
            y: view.bounds.height - totalHeight,
            width: view.bounds.width,
            height: totalHeight
        )

        let btnSize: CGFloat = 44
        let spacing: CGFloat = 60
        let centerX = toolbar.bounds.width / 2
        shareButton.frame = CGRect(
            x: centerX - spacing - btnSize / 2,
            y: 0,
            width: btnSize,
            height: barHeight
        )
        saveButton.frame = CGRect(
            x: centerX + spacing - btnSize / 2,
            y: 0,
            width: btnSize,
            height: barHeight
        )
    }

    private func toggleChrome() {
        chromeVisible.toggle()
        UIView.animate(withDuration: 0.2) {
            let alpha: CGFloat = self.chromeVisible ? 1 : 0
            self.toolbar.alpha = alpha
            self.closeButton.alpha = alpha
        }
    }

    @objc private func closeTapped() {
        animateDismiss()
    }

    @objc private func shareTapped() {
        guard let image = imageView.image else { return }
        let sheet = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        present(sheet, animated: true)
    }

    @objc private func saveTapped() {
        guard let image = imageView.image else { return }
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(imageSaved(_:error:context:)), nil)
    }

    @objc private func imageSaved(_ image: UIImage, error: Error?, context: UnsafeMutableRawPointer?) {
        let icon = UIImageView(
            image: UIImage(systemName: error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
        )
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        icon.center = view.center
        icon.alpha = 0
        view.addSubview(icon)

        UIView.animate(withDuration: 0.2, animations: {
            icon.alpha = 1
            icon.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0.5, animations: {
                icon.alpha = 0
            }) { _ in
                icon.removeFromSuperview()
            }
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
        toggleChrome()
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
        toolbar.alpha = 0
        closeButton.alpha = 0
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
