import UIKit
import AVFoundation

// MARK: - CameraPreviewViewControllerDelegate

protocol CameraPreviewViewControllerDelegate: AnyObject {
    func cameraPreviewDidCapture(_ controller: CameraPreviewViewController, image: UIImage, quad: Quad<VisionSpace>?, debugCropRect: CGRect?)
    func cameraPreviewDidFinish(_ controller: CameraPreviewViewController)
    func cameraPreviewDidCancel(_ controller: CameraPreviewViewController)
}

// MARK: - CameraPreviewViewController

final class CameraPreviewViewController: UIViewController {

    // MARK: - Dependencies

    weak var delegate: CameraPreviewViewControllerDelegate?
    private let sessionManager = ScannerSessionManager()
    private let rectangleDetector = RectangleDetector()

    // MARK: - State

    private(set) var pageCount = 0
    private var currentQuad: Quad<VisionSpace>?
    private var isCapturing = false

    // MARK: - UI

    private let overlayView = QuadrilateralOverlayView()

    private lazy var shutterButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false

        let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .ultraLight)
        btn.setImage(UIImage(systemName: "circle.inset.filled", withConfiguration: config), for: .normal)
        btn.tintColor = .white
        btn.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        return btn
    }()

    private let thumbnailView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 8
        iv.layer.borderWidth = 2
        iv.layer.borderColor = UIColor.white.cgColor
        iv.isHidden = true
        return iv
    }()

    private lazy var pageCountLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = Colors.accent
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.isHidden = true
        return label
    }()

    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionManager.startRunning()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionManager.stopRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sessionManager.previewLayer.frame = view.bounds
    }

    // MARK: - Public

    func updatePageCount(_ count: Int, lastImage: UIImage? = nil) {
        pageCount = count
        pageCountLabel.text = " \(count) "
        pageCountLabel.isHidden = count == 0
        navigationItem.rightBarButtonItem?.isEnabled = count > 0

        if let image = lastImage {
            thumbnailView.image = image
        }
        thumbnailView.isHidden = count == 0
    }

    func resumeDetection() {
        isCapturing = false
        rectangleDetector.resetStability()
    }

    /// Plays the capture animation: corrected image zooms from detected position
    /// to near-full-screen, pauses, then flies into the thumbnail.
    func animateCapturedPage(
        correctedImage: UIImage,
        quad: Quad<VisionSpace>?,
        pageCount newCount: Int,
        completion: (() -> Void)? = nil
    ) {
        // 1. Compute starting frame from detected quad in view coords
        let startRect: CGRect
        if let quad {
            let viewQuad = quad.toCaptureDevice().toView(
                using: sessionManager.previewLayer,
                clampTo: overlayView.bounds
            )
            startRect = viewQuad.boundingRect
        } else {
            let bounds = overlayView.bounds
            let size = CGSize(width: bounds.width * 0.6, height: bounds.height * 0.6)
            startRect = CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        // 2. Hide detection overlay
        overlayView.update(quad: nil, animated: false)

        // 3. Create animating image view
        let imageView = UIImageView(image: correctedImage)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .black
        imageView.layer.cornerRadius = 8
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = 0.4
        imageView.layer.shadowRadius = 12
        imageView.layer.shadowOffset = CGSize(width: 0, height: 4)
        imageView.frame = startRect
        view.addSubview(imageView)

        // 4. Compute showcase frame (centered, ~85% of preview area, preserving aspect ratio)
        let showcaseArea = overlayView.bounds.insetBy(
            dx: overlayView.bounds.width * 0.075,
            dy: overlayView.bounds.height * 0.075
        )
        let imgAspect = correctedImage.size.width / correctedImage.size.height
        let areaAspect = showcaseArea.width / showcaseArea.height
        let showcaseSize: CGSize
        if imgAspect > areaAspect {
            showcaseSize = CGSize(width: showcaseArea.width, height: showcaseArea.width / imgAspect)
        } else {
            showcaseSize = CGSize(width: showcaseArea.height * imgAspect, height: showcaseArea.height)
        }
        let showcaseRect = CGRect(
            x: overlayView.bounds.midX - showcaseSize.width / 2,
            y: overlayView.bounds.midY - showcaseSize.height / 2,
            width: showcaseSize.width,
            height: showcaseSize.height
        )

        // 5. Thumbnail destination in view coordinates
        let thumbnailFrame = thumbnailView.convert(thumbnailView.bounds, to: view)

        // 6. Phase 1: Expand to showcase
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut]
        ) {
            imageView.frame = showcaseRect
        } completion: { _ in
            // 7. Phase 2 + 3: Pause, then fly to thumbnail
            UIView.animate(
                withDuration: 0.35,
                delay: 0.4,
                options: [.curveEaseIn]
            ) {
                imageView.frame = thumbnailFrame
                imageView.layer.cornerRadius = self.thumbnailView.layer.cornerRadius
            } completion: { _ in
                imageView.removeFromSuperview()
                self.updatePageCount(newCount, lastImage: correctedImage)
                if let completion {
                    completion()
                } else {
                    self.resumeDetection()
                }
            }
        }
    }

    // MARK: - Setup

    private func setupUI() {
        view.backgroundColor = .black

        // Navigation
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(doneTapped)
        )
        navigationItem.rightBarButtonItem?.isEnabled = pageCount > 0

        // Style nav bar for camera
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.buttonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        title = "Scan Document"

        // Overlay
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)

        // Bottom bar
        let bottomBar = UIView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(bottomBar)

        bottomBar.addSubview(shutterButton)
        bottomBar.addSubview(thumbnailView)
        bottomBar.addSubview(pageCountLabel)

        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 120),

            shutterButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            shutterButton.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 16),
            shutterButton.widthAnchor.constraint(equalToConstant: 72),
            shutterButton.heightAnchor.constraint(equalToConstant: 72),

            thumbnailView.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 24),
            thumbnailView.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 48),
            thumbnailView.heightAnchor.constraint(equalToConstant: 48),

            pageCountLabel.centerXAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: -2),
            pageCountLabel.centerYAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: 2),
            pageCountLabel.heightAnchor.constraint(equalToConstant: 20),
            pageCountLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
    }

    private func setupSession() {
        // Preview layer
        view.layer.insertSublayer(sessionManager.previewLayer, at: 0)

        // Wire up delegates
        sessionManager.delegate = self
        rectangleDetector.delegate = self

        sessionManager.configure()
        feedbackGenerator.prepare()
    }

    // MARK: - Actions

    @objc private func shutterTapped() {
        performCapture()
    }

    @objc private func cancelTapped() {
        delegate?.cameraPreviewDidCancel(self)
    }

    @objc private func doneTapped() {
        delegate?.cameraPreviewDidFinish(self)
    }

    private func performCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        sessionManager.capturePhoto()
    }
}

// MARK: - ScannerSessionManagerDelegate

extension CameraPreviewViewController: ScannerSessionManagerDelegate {

    func sessionManager(_ manager: ScannerSessionManager, didOutput sampleBuffer: CMSampleBuffer) {
        guard !isCapturing else { return }
        rectangleDetector.detect(in: sampleBuffer)
    }

    func sessionManager(_ manager: ScannerSessionManager, didCapturePhoto image: UIImage) {
        let fallbackQuad = currentQuad
        DispatchQueue.global(qos: .userInitiated).async {
            if let result = RectangleDetector.detect(in: image, cropHint: fallbackQuad) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.cameraPreviewDidCapture(self, image: image, quad: result.quad, debugCropRect: result.cropRect)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.cameraPreviewDidCapture(self, image: image, quad: fallbackQuad, debugCropRect: nil)
                }
            }
        }
    }
}

// MARK: - RectangleDetectorDelegate

extension CameraPreviewViewController: RectangleDetectorDelegate {

    func rectangleDetector(_ detector: RectangleDetector, didDetect quad: Quad<VisionSpace>?) {
        currentQuad = quad

        if let quad {
            let overlayQuad = quad.toCaptureDevice().toView(
                using: sessionManager.previewLayer,
                clampTo: overlayView.bounds
            )
            overlayView.update(quad: overlayQuad)
        } else {
            overlayView.update(quad: nil)
        }
    }

    func rectangleDetectorDidStabilize(_ detector: RectangleDetector, quad: Quad<VisionSpace>) {
        feedbackGenerator.impactOccurred()
        feedbackGenerator.prepare()
        performCapture()
    }
}
