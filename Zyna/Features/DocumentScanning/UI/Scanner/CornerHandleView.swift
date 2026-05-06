import UIKit

// MARK: - CornerHandleViewDelegate

protocol CornerHandleViewDelegate: AnyObject {
    func cornerHandleDidMove(_ handle: CornerHandleView)
}

// MARK: - CornerHandleView

final class CornerHandleView: UIView {

    // MARK: - Constants

    private enum Constants {
        static let hitArea: CGFloat = 44
        static let visibleSize: CGFloat = 20
        static let borderWidth: CGFloat = 2
    }

    // MARK: - Properties

    weak var delegate: CornerHandleViewDelegate?
    let cornerIndex: Int

    /// The center of this handle in the superview's coordinate space.
    var cornerPosition: CGPoint {
        get { center }
        set { center = newValue }
    }

    // MARK: - UI

    private let circleView: UIView = {
        let v = UIView()
        v.backgroundColor = .white
        v.layer.cornerRadius = Constants.visibleSize / 2
        v.layer.borderColor = UIColor.systemBlue.cgColor
        v.layer.borderWidth = Constants.borderWidth
        v.layer.shadowColor = UIColor.black.cgColor
        v.layer.shadowOpacity = 0.3
        v.layer.shadowOffset = CGSize(width: 0, height: 1)
        v.layer.shadowRadius = 3
        v.isUserInteractionEnabled = false
        return v
    }()

    // MARK: - Init

    init(cornerIndex: Int) {
        self.cornerIndex = cornerIndex
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: Constants.hitArea, height: Constants.hitArea)))

        circleView.frame = CGRect(
            x: (Constants.hitArea - Constants.visibleSize) / 2,
            y: (Constants.hitArea - Constants.visibleSize) / 2,
            width: Constants.visibleSize,
            height: Constants.visibleSize
        )
        addSubview(circleView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Gesture

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let translation = gesture.translation(in: superview)
        center = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        gesture.setTranslation(.zero, in: superview)
        delegate?.cornerHandleDidMove(self)
    }
}
