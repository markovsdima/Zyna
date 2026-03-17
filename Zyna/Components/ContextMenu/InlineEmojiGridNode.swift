//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class InlineEmojiGridNode: ASDisplayNode {

    var onEmojiSelected: ((String) -> Void)?
    var onSearchActivated: (() -> Void)?

    private let searchIconNode = ASImageNode()
    private let searchTextNode = ASEditableTextNode()
    private let searchPillNode = ASDisplayNode()
    private let collectionNode: ASCollectionNode

    private var filteredCategories: [(name: String, emojis: [String])] = EmojiData.categories

    // MARK: - Constants

    private static let columns = 6
    private static let emojiSize: CGFloat = 40
    private static let interItemSpacing: CGFloat = 2
    private static let sectionInsetH: CGFloat = 8
    private static let headerHeight: CGFloat = 24
    private static let searchBarHeight: CGFloat = 36

    // MARK: - Init

    override init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.interItemSpacing
        layout.minimumLineSpacing = Self.interItemSpacing
        layout.sectionInset = UIEdgeInsets(top: 4, left: Self.sectionInsetH, bottom: 4, right: Self.sectionInsetH)
        layout.itemSize = CGSize(width: Self.emojiSize, height: Self.emojiSize)
        layout.headerReferenceSize = CGSize(width: 0, height: Self.headerHeight)

        collectionNode = ASCollectionNode(collectionViewLayout: layout)

        super.init()
        automaticallyManagesSubnodes = true

        backgroundColor = .secondarySystemBackground

        collectionNode.dataSource = self
        collectionNode.delegate = self
        collectionNode.backgroundColor = .clear
        collectionNode.showsVerticalScrollIndicator = false

        setupSearchBar()
    }

    // MARK: - Search Bar

    private func setupSearchBar() {
        searchPillNode.backgroundColor = .systemGray5
        searchPillNode.cornerRadius = 8
        searchPillNode.style.height = ASDimension(unit: .points, value: Self.searchBarHeight)

        searchIconNode.image = UIImage(systemName: "magnifyingglass")
        searchIconNode.tintColor = .secondaryLabel
        searchIconNode.style.preferredSize = CGSize(width: 14, height: 14)

        searchTextNode.attributedPlaceholderText = NSAttributedString(
            string: "Search",
            attributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: UIColor.placeholderText
            ]
        )
        searchTextNode.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 15),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.label
        ]
        searchTextNode.autocorrectionType = .no
        searchTextNode.returnKeyType = .done
        searchTextNode.delegate = self
        searchTextNode.scrollEnabled = false
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Search bar content: icon + text field
        searchTextNode.style.flexGrow = 1
        let searchContent = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 6,
            justifyContent: .start,
            alignItems: .center,
            children: [searchIconNode, searchTextNode]
        )
        let searchInset = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8),
            child: searchContent
        )
        let pill = ASBackgroundLayoutSpec(child: searchInset, background: searchPillNode)

        let searchBar = ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 8, left: 8, bottom: 4, right: 8),
            child: pill
        )

        collectionNode.style.flexGrow = 1
        return ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [searchBar, collectionNode]
        )
    }
}

// MARK: - ASEditableTextNodeDelegate

extension InlineEmojiGridNode: ASEditableTextNodeDelegate {

    func editableTextNodeShouldBeginEditing(_ editableTextNode: ASEditableTextNode) -> Bool {
        onSearchActivated?()
        return true
    }

    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        let query = (editableTextNode.textView.text ?? "").lowercased()
        if query.isEmpty {
            filteredCategories = EmojiData.categories
        } else {
            filteredCategories = EmojiData.categories.compactMap { category in
                let filtered = category.emojis.filter {
                    $0.contains(query) || EmojiData.names[$0]?.contains(query) == true
                }
                return filtered.isEmpty ? nil : (name: category.name, emojis: filtered)
            }
        }
        collectionNode.reloadData()
    }

    func editableTextNode(
        _ editableTextNode: ASEditableTextNode,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text == "\n" {
            editableTextNode.resignFirstResponder()
            return false
        }
        return true
    }
}

// MARK: - ASCollectionDataSource & ASCollectionDelegate

extension InlineEmojiGridNode: ASCollectionDataSource, ASCollectionDelegate {

    func numberOfSections(in collectionNode: ASCollectionNode) -> Int {
        filteredCategories.count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        numberOfItemsInSection section: Int
    ) -> Int {
        filteredCategories[section].emojis.count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        nodeBlockForItemAt indexPath: IndexPath
    ) -> ASCellNodeBlock {
        let emoji = filteredCategories[indexPath.section].emojis[indexPath.item]
        let handler = onEmojiSelected
        return {
            let cell = EmojiCellNode(emoji: emoji, onTap: handler)
            return cell
        }
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        supplementaryElementKindsInSection section: Int
    ) -> [String] {
        [UICollectionView.elementKindSectionHeader]
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        nodeForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> ASCellNode {
        EmojiSectionHeaderNode(title: filteredCategories[indexPath.section].name)
    }
}

// MARK: - Emoji Cell

private final class EmojiCellNode: ASCellNode {

    private let textNode = ASTextNode()
    private let handler: ((String) -> Void)?
    private let emoji: String

    init(emoji: String, onTap: ((String) -> Void)?) {
        self.emoji = emoji
        self.handler = onTap
        super.init()
        automaticallyManagesSubnodes = true

        textNode.attributedText = NSAttributedString(
            string: emoji,
            attributes: [.font: UIFont.systemFont(ofSize: 26)]
        )

        style.preferredSize = CGSize(width: 40, height: 40)
    }

    override func didLoad() {
        super.didLoad()
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @objc private func tapped() {
        handler?(emoji)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: [], child: textNode)
    }
}

// MARK: - Section Header Node

private final class EmojiSectionHeaderNode: ASCellNode {

    private let titleNode = ASTextNode()

    init(title: String) {
        super.init()
        automaticallyManagesSubnodes = true

        titleNode.attributedText = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4),
            child: titleNode
        )
    }
}
