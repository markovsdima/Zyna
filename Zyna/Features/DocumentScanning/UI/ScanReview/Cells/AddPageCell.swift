import UIKit

final class AddPageCell: UICollectionViewCell {

    private let iconView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .light)
        let iv = UIImageView(image: UIImage(systemName: "plus", withConfiguration: config))
        iv.tintColor = Colors.textTertiary
        iv.contentMode = .center
        return iv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 6
        contentView.layer.borderWidth = 1.5
        contentView.layer.borderColor = Colors.textTertiary.cgColor
        contentView.addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconView.sizeToFit()
        iconView.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }
}
