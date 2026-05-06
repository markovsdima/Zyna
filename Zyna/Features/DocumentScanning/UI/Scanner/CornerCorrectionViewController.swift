import UIKit

// MARK: - CornerCorrectionViewControllerDelegate

protocol CornerCorrectionViewControllerDelegate: AnyObject {
    func cornerCorrectionDidConfirm(_ controller: CornerCorrectionViewController, correctedImage: UIImage)
    func cornerCorrectionDidRetake(_ controller: CornerCorrectionViewController)
}

// MARK: - CornerCorrectionViewController

final class CornerCorrectionViewController: UIViewController {

    // MARK: - Dependencies

    weak var delegate: CornerCorrectionViewControllerDelegate?
    private let perspectiveService = PerspectiveCorrectionService()

    // MARK: - Data

    private let capturedImage: UIImage
    private let initialQuad: Quad<VisionSpace>?

    /// Set before presenting to show a red diagnostic border around the crop area.
    /// Expressed in Vision normalized coords (0…1, bottom-left origin).
    var debugCropRect: CGRect?

    // MARK: - UI

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        return iv
    }()

    private let overlayView = QuadrilateralOverlayView()
    private var handles: [CornerHandleView] = []
    private let debugCropLayer = CAShapeLayer()

    private let bottomBar: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        return v
    }()

    private let retakeButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("Retake", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        btn.tintColor = .white
        btn.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        btn.layer.cornerRadius = 24
        return btn
    }()

    private let useScanButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setTitle("Use Scan", for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        btn.tintColor = .white
        btn.backgroundColor = Colors.accent
        btn.layer.cornerRadius = 24
        return btn
    }()

    // MARK: - Layout State

    /// The rect in view coordinates where the image is actually drawn (accounting for aspect fit).
    private var imageDisplayRect: CGRect = .zero
    private var hasPositionedHandles = false

    // MARK: - Init

    init(image: UIImage, quad: Quad<VisionSpace>?) {
        self.capturedImage = image
        self.initialQuad = quad
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let barHeight: CGFloat = 100
        bottomBar.frame = CGRect(
            x: 0,
            y: view.bounds.height - barHeight,
            width: view.bounds.width,
            height: barHeight
        )

        let buttonH: CGFloat = 48
        let spacing: CGFloat = 12
        let inset: CGFloat = 24
        let totalW = bottomBar.bounds.width - inset * 2
        let buttonW = (totalW - spacing) / 2

        retakeButton.frame = CGRect(
            x: inset,
            y: 16,
            width: buttonW,
            height: buttonH
        )
        useScanButton.frame = CGRect(
            x: bottomBar.bounds.width - inset - buttonW,
            y: 16,
            width: buttonW,
            height: buttonH
        )

        let imageTop = view.safeAreaInsets.top
        imageView.frame = CGRect(
            x: 0,
            y: imageTop,
            width: view.bounds.width,
            height: max(0, bottomBar.frame.minY - imageTop)
        )

        overlayView.frame = imageView.frame

        recalculateImageRect()
        if !hasPositionedHandles {
            positionHandles()
            hasPositionedHandles = true
        }
        updateOverlayFromHandles()
        updateDebugCropBorder()
    }

    // MARK: - Setup

    private func setupUI() {
        title = "Adjust Corners"
        view.backgroundColor = .black

        // Nav bar appearance
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        // Image
        imageView.image = capturedImage
        view.addSubview(imageView)

        // Overlay
        view.addSubview(overlayView)

        // Debug crop border
        debugCropLayer.fillColor = nil
        debugCropLayer.strokeColor = UIColor.red.cgColor
        debugCropLayer.lineWidth = 1
        view.layer.addSublayer(debugCropLayer)

        // Corner handles (topLeft=0, topRight=1, bottomRight=2, bottomLeft=3)
        for i in 0..<4 {
            let handle = CornerHandleView(cornerIndex: i)
            handle.delegate = self
            view.addSubview(handle)
            handles.append(handle)
        }

        // Bottom bar
        view.addSubview(bottomBar)
        bottomBar.addSubview(retakeButton)
        bottomBar.addSubview(useScanButton)

        retakeButton.addTarget(self, action: #selector(retakeTapped), for: .touchUpInside)
        useScanButton.addTarget(self, action: #selector(useScanTapped), for: .touchUpInside)
    }

    // MARK: - Layout Helpers

    private func recalculateImageRect() {
        let imageSize = capturedImage.size
        let viewSize = imageView.bounds.size
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }

        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        var drawSize: CGSize
        if imageAspect > viewAspect {
            drawSize = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        } else {
            drawSize = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        }

        let origin = CGPoint(
            x: imageView.frame.origin.x + (viewSize.width - drawSize.width) / 2,
            y: imageView.frame.origin.y + (viewSize.height - drawSize.height) / 2
        )
        imageDisplayRect = CGRect(origin: origin, size: drawSize)
    }

    private func positionHandles() {
        guard imageDisplayRect.width > 0 else { return }

        let viewQuad: Quad<ViewSpace>
        if let initialQuad {
            viewQuad = initialQuad.toView(in: imageDisplayRect)
        } else {
            // Default: inset 10% from edges
            let inset: CGFloat = 0.1
            let r = imageDisplayRect
            viewQuad = Quad<ViewSpace>(
                topLeft: CGPoint(x: r.minX + r.width * inset, y: r.minY + r.height * inset),
                topRight: CGPoint(x: r.maxX - r.width * inset, y: r.minY + r.height * inset),
                bottomRight: CGPoint(x: r.maxX - r.width * inset, y: r.maxY - r.height * inset),
                bottomLeft: CGPoint(x: r.minX + r.width * inset, y: r.maxY - r.height * inset)
            )
        }

        let points = viewQuad.points
        for (i, handle) in handles.enumerated() {
            handle.cornerPosition = points[i]
        }
    }

    private func handleQuad() -> Quad<ViewSpace> {
        Quad<ViewSpace>(
            topLeft: handles[0].cornerPosition,
            topRight: handles[1].cornerPosition,
            bottomRight: handles[2].cornerPosition,
            bottomLeft: handles[3].cornerPosition
        )
    }

    private func updateOverlayFromHandles() {
        let quad = handleQuad()

        // Convert to overlay's local coordinate space (still ViewSpace, just offset)
        let localQuad = quad.applying { point in
            overlayView.convert(point, from: view)
        }
        overlayView.update(quad: localQuad, animated: false)
    }

    private func updateDebugCropBorder() {
        guard let crop = debugCropRect, imageDisplayRect.width > 0 else {
            debugCropLayer.path = nil
            return
        }

        let r = imageDisplayRect
        // Vision coords (bottom-left origin) → display coords (top-left origin)
        let displayRect = CGRect(
            x: r.origin.x + crop.origin.x * r.width,
            y: r.origin.y + (1 - crop.origin.y - crop.height) * r.height,
            width: crop.width * r.width,
            height: crop.height * r.height
        )

        debugCropLayer.path = UIBezierPath(rect: displayRect).cgPath
    }

    // MARK: - Actions

    @objc private func retakeTapped() {
        delegate?.cornerCorrectionDidRetake(self)
    }

    @objc private func useScanTapped() {
        let imageQuad = handleQuad().toImage(from: imageDisplayRect, imageSize: capturedImage.size)

        if let corrected = perspectiveService.correct(image: capturedImage, quad: imageQuad) {
            delegate?.cornerCorrectionDidConfirm(self, correctedImage: corrected)
        } else {
            delegate?.cornerCorrectionDidConfirm(self, correctedImage: capturedImage)
        }
    }
}

// MARK: - CornerHandleViewDelegate

extension CornerCorrectionViewController: CornerHandleViewDelegate {

    func cornerHandleDidMove(_ handle: CornerHandleView) {
        // Clamp to image display rect
        var pos = handle.cornerPosition
        pos.x = min(max(pos.x, imageDisplayRect.minX), imageDisplayRect.maxX)
        pos.y = min(max(pos.y, imageDisplayRect.minY), imageDisplayRect.maxY)
        handle.cornerPosition = pos

        updateOverlayFromHandles()
    }
}
