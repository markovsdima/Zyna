//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Visual chrome of the tab bar. Plain `UIView` with a system blur
/// background, a hairline divider, and one `ItemView` per tab.
///
/// Knows nothing about controllers — emits a tap callback with the
/// item index, and the owning `ZynaTabBarController` decides what to
/// do with it. Keeps the bar reusable.
final class ZynaTabBar: UIView {

    // MARK: - Public

    /// Standard content height, exclusive of safe area.
    static let barContentHeight: CGFloat = 49

    /// Tap on a tab item, parameter is the index.
    var onItemTapped: ((Int) -> Void)?

    private(set) var items: [ZynaTabBarItem] = []
    private(set) var selectedIndex: Int = 0

    // MARK: - Subviews

    private let blurView: UIVisualEffectView
    private let separator = UIView()
    private var itemViews: [ItemView] = []

    // MARK: - Init

    override init(frame: CGRect) {
        // .systemChromeMaterial is the same material UITabBar uses
        // by default. Looks consistent on iOS 16 and iOS 26.
        let effect = UIBlurEffect(style: .systemChromeMaterial)
        self.blurView = UIVisualEffectView(effect: effect)
        super.init(frame: frame)

        addSubview(blurView)
        addSubview(separator)
        separator.backgroundColor = UIColor.separator.withAlphaComponent(0.6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - API

    func setItems(_ items: [ZynaTabBarItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = max(0, min(selectedIndex, items.count - 1))
        rebuildItemViews()
    }

    func setSelectedIndex(_ index: Int) {
        guard index >= 0, index < items.count, index != selectedIndex else { return }
        let old = selectedIndex
        selectedIndex = index
        if old < itemViews.count {
            itemViews[old].isSelected = false
        }
        itemViews[index].isSelected = true
    }

    func setBadge(_ badge: String?, at index: Int) {
        guard index >= 0, index < items.count else { return }
        items[index].badge = badge
        if index < itemViews.count {
            itemViews[index].setBadge(badge)
        }
    }

    // MARK: - Internals

    private func rebuildItemViews() {
        for v in itemViews { v.removeFromSuperview() }
        itemViews = items.enumerated().map { idx, item in
            let v = ItemView(item: item)
            v.isSelected = (idx == selectedIndex)
            v.onTap = { [weak self] in self?.onItemTapped?(idx) }
            addSubview(v)
            return v
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        separator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)

        guard !itemViews.isEmpty else { return }
        let itemWidth = bounds.width / CGFloat(itemViews.count)
        for (idx, v) in itemViews.enumerated() {
            v.frame = CGRect(
                x: CGFloat(idx) * itemWidth,
                y: 0,
                width: itemWidth,
                height: Self.barContentHeight
            )
        }
    }
}

// MARK: - ItemView

private final class ItemView: UIView {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeBackground = UIView()
    private let badgeLabel = UILabel()

    private let item: ZynaTabBarItem

    var isSelected: Bool = false {
        didSet { applyTint() }
    }

    var onTap: (() -> Void)?

    init(item: ZynaTabBarItem) {
        self.item = item
        super.init(frame: .zero)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(badgeBackground)
        addSubview(badgeLabel)

        iconView.contentMode = .scaleAspectFit
        iconView.image = item.icon

        titleLabel.text = item.title
        titleLabel.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        titleLabel.textAlignment = .center

        badgeBackground.backgroundColor = .systemRed
        badgeLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center

        applyTint()
        setBadge(item.badge)

        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap))
        )

        isAccessibilityElement = true
        accessibilityLabel = item.title
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleTap() { onTap?() }

    private func applyTint() {
        let color: UIColor = isSelected ? AppColor.accent : .secondaryLabel
        iconView.tintColor = color
        titleLabel.textColor = color
        if isSelected, let selected = item.selectedIcon {
            iconView.image = selected
        } else {
            iconView.image = item.icon
        }
    }

    func setBadge(_ badge: String?) {
        if let badge {
            badgeBackground.isHidden = false
            badgeLabel.isHidden = false
            badgeLabel.text = badge.isEmpty ? nil : badge
        } else {
            badgeBackground.isHidden = true
            badgeLabel.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize: CGFloat = 26
        iconView.frame = CGRect(
            x: (bounds.width - iconSize) / 2,
            y: 6,
            width: iconSize,
            height: iconSize
        )
        let titleHeight: CGFloat = 12
        titleLabel.frame = CGRect(
            x: 0,
            y: bounds.height - titleHeight - 4,
            width: bounds.width,
            height: titleHeight
        )

        if !badgeBackground.isHidden {
            let isDot = badgeLabel.text == nil || badgeLabel.text?.isEmpty == true
            let bgHeight: CGFloat = isDot ? 10 : 16
            let textWidth = isDot ? 0 : badgeLabel.intrinsicContentSize.width
            let bgWidth: CGFloat = isDot ? 10 : max(16, textWidth + 8)
            let bgX = iconView.frame.maxX - 4
            let bgY = iconView.frame.minY - 2
            badgeBackground.frame = CGRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight)
            badgeBackground.layer.cornerRadius = bgHeight / 2
            badgeLabel.frame = badgeBackground.frame
        }
    }
}
