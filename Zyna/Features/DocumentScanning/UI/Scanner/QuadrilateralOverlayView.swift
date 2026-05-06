import UIKit

// MARK: - QuadrilateralOverlayView

final class QuadrilateralOverlayView: UIView {

    // MARK: - Layers

    private let dimmingLayer = CAShapeLayer()
    private let quadLayer = CAShapeLayer()

    // MARK: - State

    private var currentQuad: Quad<ViewSpace>?
    private var isShowing = false

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        dimmingLayer.fillRule = .evenOdd
        dimmingLayer.fillColor = UIColor.black.withAlphaComponent(0.4).cgColor
        layer.addSublayer(dimmingLayer)

        quadLayer.strokeColor = UIColor.systemBlue.cgColor
        quadLayer.lineWidth = 2
        quadLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15).cgColor
        quadLayer.lineJoin = .round
        quadLayer.opacity = 0
        layer.addSublayer(quadLayer)

        dimmingLayer.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimmingLayer.frame = bounds
        quadLayer.frame = bounds
        if let quad = currentQuad {
            redraw(quad: quad, animated: false)
        }
        CATransaction.commit()
    }

    // MARK: - Public

    func update(quad: Quad<ViewSpace>?, animated: Bool = true) {
        currentQuad = quad
        if let quad {
            redraw(quad: quad, animated: animated)
            if !isShowing {
                isShowing = true
                animateOpacity(to: 1)
            }
        } else {
            if isShowing {
                isShowing = false
                animateOpacity(to: 0)
            }
        }
    }

    // MARK: - Private

    private func redraw(quad: Quad<ViewSpace>, animated: Bool) {
        let quadPath = UIBezierPath()
        quadPath.move(to: quad.topLeft)
        quadPath.addLine(to: quad.topRight)
        quadPath.addLine(to: quad.bottomRight)
        quadPath.addLine(to: quad.bottomLeft)
        quadPath.close()

        let dimmingPath = UIBezierPath(rect: bounds)
        dimmingPath.append(quadPath)

        if animated {
            let strokeAnim = CABasicAnimation(keyPath: "path")
            strokeAnim.duration = 0.1
            strokeAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            quadLayer.add(strokeAnim, forKey: "pathAnim")

            let dimAnim = CABasicAnimation(keyPath: "path")
            dimAnim.duration = 0.1
            dimAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dimmingLayer.add(dimAnim, forKey: "pathAnim")
        }

        quadLayer.path = quadPath.cgPath
        dimmingLayer.path = dimmingPath.cgPath
    }

    private func animateOpacity(to value: Float) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.duration = 0.25
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        quadLayer.add(anim, forKey: "opacityAnim")
        dimmingLayer.add(anim, forKey: "opacityAnim")

        quadLayer.opacity = value
        dimmingLayer.opacity = value
    }
}
