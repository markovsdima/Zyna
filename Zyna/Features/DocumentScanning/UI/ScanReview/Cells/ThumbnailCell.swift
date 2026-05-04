import UIKit

final class ThumbnailCell: UICollectionViewCell {

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 6
        return iv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(imageView)
        contentView.layer.cornerRadius = 6
        contentView.layer.borderWidth = 2
        contentView.layer.borderColor = UIColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
    }

    func configure(with image: UIImage?, isSelected: Bool) {
        imageView.image = image
        contentView.layer.borderColor = isSelected ? Colors.accent.cgColor : UIColor.clear.cgColor
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        contentView.layer.borderColor = UIColor.clear.cgColor
    }
}
