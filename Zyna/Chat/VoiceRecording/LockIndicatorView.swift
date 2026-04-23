//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class LockIndicatorView: UIView {

    private let lockImageView = UIImageView()
    private let chevronImageView = UIImageView()
    private let capsuleBackground = UIView()

    private static let capsuleSize = CGSize(width: 40, height: 80)
    private static let lockThreshold: CGFloat = 0.7

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        let size = Self.capsuleSize

        capsuleBackground.backgroundColor = .systemGray5
        capsuleBackground.layer.cornerRadius = size.width / 2
        capsuleBackground.frame = CGRect(origin: .zero, size: size)
        addSubview(capsuleBackground)

        lockImageView.image = AppIcon.lockOpen.rendered(size: 20, color: .secondaryLabel)
        lockImageView.contentMode = .center
        lockImageView.frame = CGRect(x: 0, y: 12, width: size.width, height: 28)
        addSubview(lockImageView)

        chevronImageView.image = AppIcon.chevronUp.rendered(size: 12, color: .tertiaryLabel)
        chevronImageView.contentMode = .center
        chevronImageView.frame = CGRect(x: 0, y: 46, width: size.width, height: 20)
        addSubview(chevronImageView)

        self.frame.size = size
        alpha = 0
    }

    // MARK: - Public

    /// Show with fade-in animation. Call after adding to superview and setting initial position.
    func show() {
        UIView.animate(withDuration: 0.2) {
            self.alpha = 1
        }
    }

    /// Update lock progress (0 = at mic button, 1 = threshold reached).
    func updateProgress(_ progress: CGFloat) {
        let clamped = min(max(progress, 0), 1)

        // Switch icon at threshold
        let isLocked = clamped >= Self.lockThreshold
        let icon: AppIcon = isLocked ? .lockClosed : .lockOpen
        let color: UIColor = isLocked ? .label : .secondaryLabel
        lockImageView.image = icon.rendered(size: 20, color: color)

        // Fade out chevron as we approach lock
        chevronImageView.alpha = max(0, 1 - clamped * 2)
    }

    /// Animate the "snap to locked" effect and disappear.
    func snapAndDismiss(completion: @escaping () -> Void) {
        lockImageView.image = AppIcon.lockClosed.rendered(size: 20, color: AppColor.accent)

        UIView.animate(withDuration: 0.15, animations: {
            self.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        }) { _ in
            UIView.animate(withDuration: 0.2, animations: {
                self.transform = .identity
                self.alpha = 0
            }) { _ in
                self.removeFromSuperview()
                completion()
            }
        }
    }

    /// Remove without snap animation.
    func dismiss() {
        UIView.animate(withDuration: 0.15, animations: {
            self.alpha = 0
        }) { _ in
            self.removeFromSuperview()
        }
    }
}
