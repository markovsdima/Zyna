//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ChatThemeSettingsViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private let previewHeaderView = UIView()
    private let previousThemeButton = UIButton(type: .system)
    private let nextThemeButton = UIButton(type: .system)
    private let themeTitleLabel = UILabel()
    private let previewView: ChatThemePreviewView
    private var selectedTheme: ChatBubbleTheme
    private var selectedThemeIndex: Int

    override init() {
        let theme = ChatBubbleThemeStore.shared.selectedTheme
        self.selectedTheme = theme
        self.selectedThemeIndex = ChatBubbleTheme.all.firstIndex(of: theme) ?? 0
        self.previewView = ChatThemePreviewView(theme: theme)
        super.init(node: SettingsScreenNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupGlassTopBar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        glassTopBar.updateLayout(in: view)
        updateTableInsets()
        updatePreviewHeaderLayout()
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .appBG
        tableView.separatorStyle = .singleLine
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.rowHeight = 56
        setupPreviewControls()
        previewHeaderView.addSubview(previewView)
        tableView.tableHeaderView = previewHeaderView
        view.addSubview(tableView)
        node.tableView = tableView
    }

    private func setupPreviewControls() {
        themeTitleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        themeTitleLabel.textColor = .label
        themeTitleLabel.textAlignment = .center
        themeTitleLabel.adjustsFontSizeToFitWidth = true
        themeTitleLabel.minimumScaleFactor = 0.8
        previewHeaderView.addSubview(themeTitleLabel)

        configureThemeStepButton(
            previousThemeButton,
            icon: AppIcon.chevronBackward.rendered(size: 17, weight: .semibold, color: AppColor.accent),
            accessibilityLabel: String(localized: "Previous Theme"),
            action: #selector(previousThemeTapped)
        )
        configureThemeStepButton(
            nextThemeButton,
            icon: AppIcon.chevronForward.rendered(size: 17, weight: .semibold, color: AppColor.accent),
            accessibilityLabel: String(localized: "Next Theme"),
            action: #selector(nextThemeTapped)
        )
        updateThemeControls()
    }

    private func configureThemeStepButton(
        _ button: UIButton,
        icon: UIImage,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.setImage(icon, for: .normal)
        button.backgroundColor = .secondarySystemGroupedBackground
        button.layer.cornerRadius = 17
        button.clipsToBounds = true
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        previewHeaderView.addSubview(button)
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = tableView
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        let backIcon = AppIcon.chevronBackward.rendered(
            size: 17,
            weight: .semibold,
            color: AppColor.accent
        )
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(text: String(localized: "Chat Theme"), subtitle: nil)
        ]
    }

    private func updateTableInsets() {
        let top = glassTopBar.coveredHeight
        if abs(tableView.contentInset.top - top) > 0.5 {
            tableView.contentInset.top = top
            tableView.verticalScrollIndicatorInsets.top = top
        }
        let bottom = max(view.safeAreaInsets.bottom + 16, 16)
        if abs(tableView.contentInset.bottom - bottom) > 0.5 {
            tableView.contentInset.bottom = bottom
            tableView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    private func updatePreviewHeaderLayout() {
        guard tableView.bounds.width > 0 else { return }
        let height: CGFloat = 260
        let horizontalInset: CGFloat = 20
        let buttonSize: CGFloat = 34
        let controlsY: CGFloat = 14
        previousThemeButton.frame = CGRect(
            x: horizontalInset,
            y: controlsY,
            width: buttonSize,
            height: buttonSize
        )
        nextThemeButton.frame = CGRect(
            x: tableView.bounds.width - horizontalInset - buttonSize,
            y: controlsY,
            width: buttonSize,
            height: buttonSize
        )
        themeTitleLabel.frame = CGRect(
            x: horizontalInset + buttonSize + 12,
            y: controlsY - 2,
            width: max(0, tableView.bounds.width - (horizontalInset + buttonSize + 12) * 2),
            height: buttonSize + 4
        )
        let previewFrame = CGRect(
            x: horizontalInset,
            y: 58,
            width: tableView.bounds.width - horizontalInset * 2,
            height: 186
        )
        if previewHeaderView.frame.width != tableView.bounds.width ||
            previewHeaderView.frame.height != height {
            previewHeaderView.frame = CGRect(
                x: 0,
                y: 0,
                width: tableView.bounds.width,
                height: height
            )
            tableView.tableHeaderView = previewHeaderView
        }
        previewView.frame = previewFrame
    }

    private func selectTheme(at index: Int) {
        let themes = ChatBubbleTheme.all
        guard !themes.isEmpty else { return }
        let normalizedIndex = (index % themes.count + themes.count) % themes.count
        let theme = themes[normalizedIndex]
        guard theme != selectedTheme else {
            selectedThemeIndex = normalizedIndex
            updateThemeControls()
            return
        }

        selectedThemeIndex = normalizedIndex
        selectedTheme = theme
        ChatBubbleThemeStore.shared.setSelectedTheme(id: theme.id)
        previewView.theme = theme
        updateThemeControls()
        tableView.reloadData()
    }

    private func updateThemeControls() {
        themeTitleLabel.text = selectedTheme.title
        let hasMultipleThemes = ChatBubbleTheme.all.count > 1
        previousThemeButton.isEnabled = hasMultipleThemes
        nextThemeButton.isEnabled = hasMultipleThemes
        previousThemeButton.alpha = hasMultipleThemes ? 1.0 : 0.45
        nextThemeButton.alpha = hasMultipleThemes ? 1.0 : 0.45
    }

    @objc private func previousThemeTapped() {
        selectTheme(at: selectedThemeIndex - 1)
    }

    @objc private func nextThemeTapped() {
        selectTheme(at: selectedThemeIndex + 1)
    }
}

extension ChatThemeSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        ChatBubbleTheme.all.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(localized: "Outgoing Bubbles")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "themeCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        let theme = ChatBubbleTheme.all[indexPath.row]

        cell.textLabel?.text = theme.title
        cell.textLabel?.font = UIFont.systemFont(ofSize: 17)
        cell.imageView?.image = ChatThemeSwatchImage.make(theme: theme)
        cell.accessoryType = theme == selectedTheme ? .checkmark : .none
        cell.tintColor = AppColor.accent
        cell.selectionStyle = .default
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectTheme(at: indexPath.row)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

private enum ChatThemeSwatchImage {
    static func make(theme: ChatBubbleTheme, size: CGFloat = 34) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            context.cgContext.addEllipse(in: rect.insetBy(dx: 1, dy: 1))
            context.cgContext.clip()

            let colors = theme.outgoingGradientColors
            if colors.count <= 1 {
                context.cgContext.setFillColor((colors.first ?? .clear).cgColor)
                context.cgContext.fill(rect)
            }
            let cgColors = colors.map { $0.cgColor } as CFArray
            let locations = BubbleGradientStops.cgLocations(for: colors.count)
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: cgColors,
                locations: locations
            ) {
                let start = CGPoint(
                    x: theme.startPoint.x * size,
                    y: theme.startPoint.y * size
                )
                let end = CGPoint(
                    x: theme.endPoint.x * size,
                    y: theme.endPoint.y * size
                )
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: start,
                    end: end,
                    options: []
                )
            }

            context.cgContext.resetClip()
            context.cgContext.setStrokeColor(UIColor.separator.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
}

private final class ChatThemePreviewView: UIView {

    var theme: ChatBubbleTheme {
        didSet { applyTheme() }
    }

    private let outgoingGradientLayer = CAGradientLayer()
    private let outgoingMaskLayer = CAShapeLayer()
    private let incomingBubble = PreviewBubbleView(
        text: String(localized: "How does this look?"),
        time: "12:41",
        style: .incoming
    )
    private let outgoingBubble = PreviewBubbleView(
        text: String(localized: "Clean. Keep it."),
        time: "12:42",
        style: .outgoing
    )
    private let shortOutgoingBubble = PreviewBubbleView(
        text: String(localized: "Done"),
        time: "12:43",
        style: .outgoing
    )

    init(theme: ChatBubbleTheme) {
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = AppColor.chatBackground
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        outgoingGradientLayer.mask = outgoingMaskLayer
        layer.addSublayer(outgoingGradientLayer)
        addSubview(incomingBubble)
        addSubview(outgoingBubble)
        addSubview(shortOutgoingBubble)
        applyTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outgoingGradientLayer.frame = bounds
        let width = bounds.width
        let horizontalInset: CGFloat = 16

        let incomingWidth = min(width * 0.72, 230)
        incomingBubble.frame = CGRect(
            x: horizontalInset,
            y: 18,
            width: incomingWidth,
            height: 44
        )

        let outgoingWidth = min(width * 0.76, 246)
        outgoingBubble.frame = CGRect(
            x: width - horizontalInset - outgoingWidth,
            y: 76,
            width: outgoingWidth,
            height: 52
        )

        let shortWidth = min(width * 0.48, 150)
        shortOutgoingBubble.frame = CGRect(
            x: width - horizontalInset - shortWidth,
            y: 142,
            width: shortWidth,
            height: 36
        )
        updateOutgoingMask()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        backgroundColor = AppColor.chatBackground
        applyTheme()
    }

    private func applyTheme() {
        incomingBubble.colors = BubbleGradientRole.incoming.colors(
            traits: traitCollection,
            outgoingTheme: theme
        )
        outgoingGradientLayer.colors = theme.outgoingGradientColors.map {
            $0.resolvedColor(with: traitCollection).cgColor
        }
        outgoingGradientLayer.locations = BubbleGradientStops.layerLocations(
            for: theme.outgoingGradientColors.count
        )
        outgoingGradientLayer.startPoint = theme.startPoint
        outgoingGradientLayer.endPoint = theme.endPoint
    }

    private func updateOutgoingMask() {
        let path = UIBezierPath()
        path.append(bubblePath(for: outgoingBubble.frame))
        path.append(bubblePath(for: shortOutgoingBubble.frame))
        outgoingMaskLayer.frame = bounds
        outgoingMaskLayer.path = path.cgPath
    }

    private func bubblePath(for frame: CGRect) -> UIBezierPath {
        UIBezierPath(
            roundedRect: frame,
            cornerRadius: MessageCellHelpers.bubbleCornerRadius
        )
    }
}

private final class PreviewBubbleView: UIView {

    enum Style {
        case incoming
        case outgoing
    }

    var colors: [UIColor] = [] {
        didSet { updateGradientColors() }
    }

    private let gradientLayer = CAGradientLayer()
    private let textLabel = UILabel()
    private let timeLabel = UILabel()
    private let style: Style

    init(text: String, time: String, style: Style) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = MessageCellHelpers.bubbleCornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        if style == .incoming {
            layer.insertSublayer(gradientLayer, at: 0)
        }

        textLabel.text = text
        textLabel.font = UIFont.systemFont(ofSize: 15)
        textLabel.numberOfLines = 1
        textLabel.lineBreakMode = .byTruncatingTail
        addSubview(textLabel)

        timeLabel.text = time
        timeLabel.font = UIFont.systemFont(ofSize: 11)
        timeLabel.textAlignment = .right
        addSubview(timeLabel)

        applyTextColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if style == .incoming {
            gradientLayer.frame = bounds
        }

        let horizontalInset: CGFloat = 12
        let verticalInset: CGFloat = 7
        let timeWidth: CGFloat = 42
        let timeHeight: CGFloat = 14
        let textWidth = max(0, bounds.width - horizontalInset * 2 - timeWidth - 4)

        textLabel.frame = CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: textWidth,
            height: bounds.height - verticalInset * 2
        )
        timeLabel.frame = CGRect(
            x: bounds.width - horizontalInset - timeWidth,
            y: bounds.height - verticalInset - timeHeight + 1,
            width: timeWidth,
            height: timeHeight
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        applyTextColors()
        updateGradientColors()
    }

    private func applyTextColors() {
        switch style {
        case .incoming:
            textLabel.textColor = AppColor.bubbleForegroundIncoming
            timeLabel.textColor = AppColor.bubbleTimestampIncoming
        case .outgoing:
            textLabel.textColor = AppColor.bubbleForegroundOutgoing
            timeLabel.textColor = AppColor.bubbleTimestampOutgoing
        }
    }

    private func updateGradientColors() {
        guard style == .incoming else { return }
        gradientLayer.colors = colors.map {
            $0.resolvedColor(with: traitCollection).cgColor
        }
        gradientLayer.locations = BubbleGradientStops.layerLocations(for: colors.count)
    }
}
