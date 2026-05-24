//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class RoomAddToSpaceViewController:
    ASDKViewController<RoomAddToSpaceNode>,
    ASTableDataSource,
    ASTableDelegate {

    var onBack: (() -> Void)?
    var onSpaceAdded: ((RoomSpaceAddCandidate) -> Void)?

    private let viewModel: RoomAddToSpaceViewModel
    private let glassTopBar = GlassTopBar()
    private let searchHeader = RoomAddToSpaceSearchHeaderView()

    init(viewModel: RoomAddToSpaceViewModel) {
        self.viewModel = viewModel
        super.init(node: RoomAddToSpaceNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTable()
        setupGlassTopBar()
        setupSearchHeader()
        bindViewModel()
        viewModel.loadSpaces()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
        updateTableInsets()
        updateSearchHeaderFrame()
    }

    private func setupTable() {
        node.tableNode.dataSource = self
        node.tableNode.delegate = self
        node.tableNode.view.separatorStyle = .none
        node.tableNode.view.keyboardDismissMode = .onDrag
        node.tableNode.view.contentInsetAdjustmentBehavior = .never
        node.tableNode.view.alwaysBounceVertical = true
        node.tableNode.view.backgroundColor = .systemBackground
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .systemBackground
        glassTopBar.sourceView = node.tableNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        glassTopBar.items = [
            .circleButton(
                icon: AppIcon.chevronBackward.template(size: 17, weight: .semibold),
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(text: viewModel.title, subtitle: nil)
        ]
    }

    private func setupSearchHeader() {
        searchHeader.configure(subtitle: viewModel.subtitle)
        searchHeader.onSearchQueryChanged = { [weak self] query in
            self?.viewModel.updateSearchQuery(query)
        }
        node.tableNode.view.tableHeaderView = searchHeader
    }

    private func bindViewModel() {
        viewModel.onChanged = { [weak self] in
            guard let self else { return }
            self.node.tableNode.reloadData()
            GlassService.shared.setNeedsCapture()
        }
        viewModel.onAdded = { [weak self] candidate in
            self?.onSpaceAdded?(candidate)
        }
        viewModel.onError = { [weak self] message in
            self?.showError(message)
        }
    }

    private func updateTableInsets() {
        let top = glassTopBar.coveredHeight + 8
        if node.tableNode.contentInset.top != top {
            var contentInset = node.tableNode.contentInset
            contentInset.top = top
            node.tableNode.contentInset = contentInset
        }
        if node.tableNode.view.verticalScrollIndicatorInsets.top != top {
            var indicatorInsets = node.tableNode.view.verticalScrollIndicatorInsets
            indicatorInsets.top = top
            node.tableNode.view.verticalScrollIndicatorInsets = indicatorInsets
        }

        let bottom = max(view.safeAreaInsets.bottom + 16, 16)
        if node.tableNode.contentInset.bottom != bottom {
            var contentInset = node.tableNode.contentInset
            contentInset.bottom = bottom
            node.tableNode.contentInset = contentInset
        }
        if node.tableNode.view.verticalScrollIndicatorInsets.bottom != bottom {
            var indicatorInsets = node.tableNode.view.verticalScrollIndicatorInsets
            indicatorInsets.bottom = bottom
            node.tableNode.view.verticalScrollIndicatorInsets = indicatorInsets
        }
    }

    private func updateSearchHeaderFrame() {
        let targetFrame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 74)
        guard searchHeader.frame != targetFrame else { return }
        searchHeader.frame = targetFrame
        node.tableNode.view.tableHeaderView = searchHeader
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Could not add to Storyline"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        max(1, viewModel.candidates.count)
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let candidates = viewModel.candidates
        guard !candidates.isEmpty else {
            let message = viewModel.emptyMessage
            return { SpaceEmptyChatsCellNode(message: message) }
        }

        guard candidates.indices.contains(indexPath.row) else {
            return { ASCellNode() }
        }

        let candidate = candidates[indexPath.row]
        let isAdding = viewModel.addingSpaceId == candidate.id
        return { RoomAddToSpaceCellNode(candidate: candidate, isAdding: isAdding) }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        guard viewModel.candidates.indices.contains(indexPath.row) else { return }
        viewModel.addSpace(at: indexPath.row)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

final class RoomAddToSpaceNode: ScreenNode {
    weak var glassTopBar: ASDisplayNode?
    let tableNode = ASTableNode(style: .plain)

    override init() {
        super.init()
        automaticallyManagesSubnodes = false
        backgroundColor = .systemBackground
        tableNode.backgroundColor = .systemBackground
        addSubnode(tableNode)
    }

    override func layout() {
        super.layout()
        tableNode.frame = bounds
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar?.view, bar.superview === view {
                elements.append(bar)
            }
            elements.append(tableNode.view)
            return elements
        }
        set { }
    }
}

private final class RoomAddToSpaceSearchHeaderView: UIView {

    var onSearchQueryChanged: ((String) -> Void)?

    private let subtitleLabel = UILabel()
    private let searchField = UITextField()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(subtitle: String) {
        subtitleLabel.text = subtitle
    }

    private func setupViews() {
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholder = String(localized: "Search")
        searchField.backgroundColor = .secondarySystemBackground
        searchField.layer.cornerRadius = 10
        searchField.leftView = makeSearchIcon()
        searchField.leftViewMode = .always
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.font = .systemFont(ofSize: 16)
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(subtitleLabel)
        addSubview(searchField)

        NSLayoutConstraint.activate([
            subtitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            searchField.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 36)
        ])

        isAccessibilityElement = false
        accessibilityElements = [subtitleLabel, searchField]
    }

    @objc private func searchChanged() {
        onSearchQueryChanged?(searchField.text ?? "")
    }

    private func makeSearchIcon() -> UIView {
        let icon = UIImageView(image: AppIcon.magnifyingGlass.template(size: 14, weight: .medium))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 36))
        icon.frame = container.bounds
        container.addSubview(icon)
        return container
    }
}

private final class RoomAddToSpaceCellNode: ZynaCellNode {

    private enum Metrics {
        static let avatarSize = CGSize(width: 42, height: 42)
        static let avatarCornerRadius: CGFloat = 10
        static let avatarThumbSize = Int(avatarSize.width * ScreenConstants.scale)
    }

    private let candidate: RoomSpaceAddCandidate
    private let isAdding: Bool
    private let avatarBackgroundNode = ASImageNode()
    private let avatarImageNode = ASImageNode()
    private let titleNode = ASTextNode()
    private let subtitleNode = ASTextNode()
    private let statusBackgroundNode = ASDisplayNode()
    private let statusTextNode = ASTextNode()
    private let separatorNode = ASDisplayNode()

    init(candidate: RoomSpaceAddCandidate, isAdding: Bool) {
        self.candidate = candidate
        self.isAdding = isAdding
        super.init()
        automaticallyManagesSubnodes = true
        setupNodes()
        setupAccessibility()
    }

    private func setupNodes() {
        backgroundColor = .systemBackground

        let avatar = AvatarViewModel(
            userId: candidate.id,
            displayName: candidate.displayName,
            mxcAvatarURL: candidate.avatarURL
        )
        avatarBackgroundNode.image = avatar.roundedRectImage(
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            fontSize: 15
        )
        avatarBackgroundNode.isLayerBacked = true

        avatarImageNode.contentMode = .scaleAspectFill
        avatarImageNode.isLayerBacked = true
        if let mxc = candidate.avatarURL {
            if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: Metrics.avatarThumbSize) {
                avatarImageNode.image = Self.roundedAvatarImage(cached, cacheKey: mxc)
            } else {
                loadAvatarImage()
            }
        }

        titleNode.attributedText = NSAttributedString(
            string: candidate.displayName.isEmpty ? String(localized: "Untitled") : candidate.displayName,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: candidate.canAddSpaceSideLink ? UIColor.label : UIColor.secondaryLabel
            ]
        )
        titleNode.maximumNumberOfLines = 1
        titleNode.truncationMode = .byTruncatingTail

        subtitleNode.attributedText = NSAttributedString(
            string: subtitleText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 13),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        subtitleNode.maximumNumberOfLines = 1
        subtitleNode.truncationMode = .byTruncatingTail

        statusBackgroundNode.backgroundColor = statusColor.withAlphaComponent(0.13)
        statusBackgroundNode.cornerRadius = 11

        statusTextNode.attributedText = NSAttributedString(
            string: statusText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: statusColor
            ]
        )
        statusTextNode.maximumNumberOfLines = 1

        separatorNode.backgroundColor = UIColor.separator
    }

    private var subtitleText: String {
        if candidate.hasSpaceSideLink {
            return candidate.status?.title ?? String(localized: "Already added")
        }

        if !candidate.canEditSpaceSide {
            return String(localized: "No permission to edit this Storyline")
        }

        if candidate.hasRoomSideLink {
            return String(localized: "Declared by Chat")
        }

        if let roomCount = candidate.roomCount,
           let spaceCount = candidate.spaceCount {
            let chats = String.localizedStringWithFormat(
                String(localized: "%lld chats"),
                Int64(roomCount)
            )
            let tracks = String.localizedStringWithFormat(
                String(localized: "%lld tracks"),
                Int64(spaceCount)
            )
            return "\(chats) · \(tracks)"
        }

        return String(localized: "Ready to add")
    }

    private var statusText: String {
        if isAdding {
            return String(localized: "Adding...")
        }
        if candidate.hasSpaceSideLink {
            return String(localized: "Already added")
        }
        if candidate.canAddSpaceSideLink {
            return String(localized: "Add")
        }
        return String(localized: "Locked")
    }

    private var statusColor: UIColor {
        if isAdding || candidate.canAddSpaceSideLink {
            return AppColor.accent
        }
        if candidate.hasSpaceSideLink {
            return .systemGreen
        }
        return .tertiaryLabel
    }

    private func loadAvatarImage() {
        guard let mxc = candidate.avatarURL else { return }
        let size = Metrics.avatarThumbSize
        Task { [weak self] in
            if let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) {
                self?.avatarImageNode.image = Self.roundedAvatarImage(image, cacheKey: mxc)
                return
            }
            try? await Task.sleep(for: .seconds(1))
            guard let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: size) else { return }
            self?.avatarImageNode.image = Self.roundedAvatarImage(image, cacheKey: mxc)
        }
    }

    private static func roundedAvatarImage(_ image: UIImage, cacheKey: String) -> UIImage {
        RoundedImageCache.roundedImage(
            source: image,
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            cacheKey: cacheKey
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        avatarBackgroundNode.style.preferredSize = Metrics.avatarSize
        avatarImageNode.style.preferredSize = Metrics.avatarSize
        let avatar = ASOverlayLayoutSpec(child: avatarBackgroundNode, overlay: avatarImageNode)

        titleNode.style.flexGrow = 1
        titleNode.style.flexShrink = 1
        subtitleNode.style.flexGrow = 1
        subtitleNode.style.flexShrink = 1

        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 3,
            justifyContent: .center,
            alignItems: .stretch,
            children: [titleNode, subtitleNode]
        )
        textStack.style.flexGrow = 1
        textStack.style.flexShrink = 1

        let statusInsets = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8),
            child: statusTextNode
        )
        let status = ASBackgroundLayoutSpec(child: statusInsets, background: statusBackgroundNode)

        let row = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .center,
            children: [avatar, textStack, status]
        )

        let content = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16),
            child: row
        )

        separatorNode.style.preferredSize = CGSize(width: constrainedSize.max.width, height: 0.5)
        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [content, separatorNode]
        )
    }

    private func setupAccessibility() {
        isAccessibilityElement = true
        accessibilityLabel = "\(candidate.displayName), \(subtitleText), \(statusText)"
        accessibilityTraits = candidate.canAddSpaceSideLink ? .button : .notEnabled
    }

    override func didLoad() {
        super.didLoad()
        backgroundColor = .systemBackground

        let highlightedBackground = UIView()
        highlightedBackground.backgroundColor = UIColor.systemGray6
        selectedBackgroundView = highlightedBackground
    }
}
