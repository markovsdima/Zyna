//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

private var chatListIdentifierKey: UInt8 = 0

extension ASCellNode {
    /// Capture the datasource identity when Texture requests the node block.
    /// Do not use nodeModel for this: Texture treats it as permission to reuse
    /// a node during reload, but our cells are configured by their factory.
    var chatListIdentifier: String? {
        get { objc_getAssociatedObject(self, &chatListIdentifierKey) as? String }
        set { objc_setAssociatedObject(self, &chatListIdentifierKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

/// The full chat owns interactions and content; this object owns the Texture
/// collection and its layout. Rows retain newest-first, inverted coordinates.
final class ChatMessageList: NSObject, ASCollectionDataSource, ASCollectionDelegate,
    ASCollectionViewLayoutInspecting {
    let node: ASCollectionNode
    let layout: ChatCollectionLayout
    weak var delegate: UIScrollViewDelegate?
    var numberOfRows: (() -> Int)?
    var nodeBlock: ((IndexPath) -> ASCellNodeBlock)?
    var itemIdentifier: ((IndexPath) -> String)?
    var shouldFetch: (() -> Bool)?
    var beginFetch: ((ASBatchContext) -> Void)?

    override init() {
        layout = ChatCollectionLayout()
        node = ASCollectionNode(frame: .zero, collectionViewLayout: layout, layoutFacilitator: layout)
        super.init()
        node.inverted = true
        layout.textureNode = node
        node.dataSource = self
        node.delegate = self
        node.layoutInspector = self
        node.view.alwaysBounceVertical = true
        node.backgroundColor = AppColor.chatBackground
    }

    var view: ASCollectionView { node.view }
    var bounds: CGRect { node.bounds }
    var contentInset: UIEdgeInsets {
        get { node.contentInset }
        set { node.contentInset = newValue }
    }
    var contentOffset: CGPoint {
        get { node.contentOffset }
        set { setContentOffset(newValue, animated: false) }
    }

    func setContentOffset(_ offset: CGPoint, animated: Bool) {
        node.setContentOffset(offset, animated: animated)
    }

    func indexPathsForVisibleItems() -> [IndexPath] {
        node.indexPathsForVisibleItems
    }

    func nodeForItem(at path: IndexPath) -> ASCellNode? {
        node.nodeForItem(at: path)
    }

    /// Input is in the datasource's index space; convert through the node
    /// before asking UIKit for geometry while another batch is preparing.
    func rectForItem(at path: IndexPath) -> CGRect {
        guard let cell = nodeForItem(at: path), let committed = committedIndexPath(for: cell) else { return .zero }
        return committedRect(at: committed)
    }

    func committedIndexPath(for cell: ASCellNode) -> IndexPath? {
        view.indexPath(for: cell)
    }

    func committedRect(at path: IndexPath) -> CGRect {
        layout.layoutAttributesForItem(at: path)?.frame ?? .zero
    }

    var committedVisiblePaths: [IndexPath] {
        view.indexPathsForVisibleItems
    }

    func committedNode(at path: IndexPath) -> ASCellNode? {
        view.nodeForItem(at: path)
    }

    func canNavigate(to path: IndexPath) -> Bool {
        guard let cell = nodeForItem(at: path) else { return false }
        return committedIndexPath(for: cell) != nil
    }

    func reloadData() { node.reloadData() }

    func performBatch(
        animated: Bool, preservingViewport: Bool,
        deletions: [IndexPath] = [], insertions: [IndexPath] = [],
        moves: [(from: IndexPath, to: IndexPath)] = [], reloads: [IndexPath] = [],
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard !deletions.isEmpty || !insertions.isEmpty || !moves.isEmpty || !reloads.isEmpty else {
            completion(true)
            return
        }
        // All item mutations, including appearance-only reloads, must submit
        // one policy per Texture change set. A bare reload creates its own
        // change set and could otherwise consume the next batch's policy.
        let batch = layout.enqueueBatch(preservesViewport: preservingViewport)
        node.performBatch(animated: animated, updates: { [node] in
            if !deletions.isEmpty { node.deleteItems(at: deletions) }
            if !insertions.isEmpty { node.insertItems(at: insertions) }
            for move in moves { node.moveItem(at: move.from, to: move.to) }
            if !reloads.isEmpty { node.reloadItems(at: reloads) }
        }) { [layout] finished in
            layout.complete(batch)
            completion(finished)
        }
    }

    func onDidFinishProcessingUpdates(_ completion: @escaping () -> Void) {
        node.onDidFinishProcessingUpdates(completion)
    }

    func scrollToItem(at path: IndexPath, at position: UICollectionView.ScrollPosition, animated: Bool) {
        node.scrollToItem(at: path, at: position, animated: animated)
    }

    func collectionNode(_ collectionNode: ASCollectionNode, numberOfItemsInSection section: Int) -> Int { numberOfRows?() ?? 0 }
    func collectionNode(_ collectionNode: ASCollectionNode, nodeBlockForItemAt path: IndexPath) -> ASCellNodeBlock {
        let identifier = itemIdentifier?(path)
        let makeNode = nodeBlock?(path) ?? { ASCellNode() }
        return {
            let node = makeNode()
            node.chatListIdentifier = identifier
            // Late asynchronous measurements should compensate immediately.
            // Explicit animated batches still control arrivals and removals.
            node.shouldAnimateSizeChanges = false
            return node
        }
    }
    func collectionView(_ collectionView: ASCollectionView, constrainedSizeForNodeAt path: IndexPath) -> ASSizeRange {
        let width = max(1, collectionView.bounds.width)
        return ASSizeRange(min: CGSize(width: width, height: 0), max: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    func scrollableDirections() -> ASScrollDirection { [.up, .down] }
    func shouldBatchFetch(for collectionNode: ASCollectionNode) -> Bool { shouldFetch?() ?? false }
    func collectionNode(_ collectionNode: ASCollectionNode, willBeginBatchFetchWith context: ASBatchContext) { beginFetch?(context) }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { delegate?.scrollViewDidScroll?(scrollView) }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { delegate?.scrollViewWillBeginDragging?(scrollView) }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity, targetContentOffset: targetContentOffset)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate) }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { delegate?.scrollViewDidEndDecelerating?(scrollView) }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { delegate?.scrollViewDidEndScrollingAnimation?(scrollView) }
}
