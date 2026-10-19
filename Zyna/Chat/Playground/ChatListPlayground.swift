//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG || CHAT_LIST_PLAYGROUND
import AsyncDisplayKit
import UIKit

enum ChatListPlaygroundSettings {
    private static let key = "com.zyna.debug.chatListPlayground"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum ChatPlaygroundMotion {
    case dragging, decelerating, idle
}

struct ChatPlaygroundItem {
    let id: String
    let row: ChatTimelineRow
    let makeNode: () -> ChatPlaygroundRowNode
    var configuration = 0

    func hasSameLayout(as other: ChatPlaygroundItem) -> Bool {
        row == other.row && configuration == other.configuration
    }

    static func id(for row: ChatTimelineRow) -> String { row.listIdentifier }
}

struct ChatPlaygroundSnapshot {
    let items: [ChatPlaygroundItem]
    let geometry: ChatListGeometry
    let width: CGFloat
    let preparedNodes: [String: ChatPlaygroundRowNode]

    /// A thumbnail can reveal its real aspect ratio after measurement.
    /// Unchanged rows retain the latest committed height, not a stale
    /// measurement cache entry from before that thumbnail arrived.
    func geometry(
        preserving oldItems: [ChatPlaygroundItem], geometry old: ChatListGeometry,
        width oldWidth: CGFloat
    ) -> ChatListGeometry {
        guard oldWidth == width else { return geometry }
        let oldByID = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
        let heights = items.enumerated().map { index, item in
            if let previous = oldByID[item.id], item.hasSameLayout(as: previous),
               let oldIndex = old.indices[item.id] {
                return old.heights[oldIndex]
            }
            return geometry.heights[index]
        }
        return ChatListGeometry(ids: geometry.ids, heights: heights)
    }
}

/// The Custom prototype measures real cells on a serial worker. It retains
/// nodes only around the viewport and caches heights for the loaded history.
final class ChatPlaygroundPreparation {
    private struct Measurement {
        let row: ChatTimelineRow
        let width: CGFloat
        let height: CGFloat
        let configuration: Int
    }
    private let queue = DispatchQueue(label: "com.zyna.chat.playground.layout", qos: .userInitiated)
    private var measurements: [String: Measurement] = [:]

    func prepare(
        _ items: [ChatPlaygroundItem], width: CGFloat,
        completion: @escaping (ChatPlaygroundSnapshot) -> Void
    ) {
        queue.async { [self] in
            var heights: [CGFloat] = []
            var nodes: [String: ChatPlaygroundRowNode] = [:]
            var retained: [String: Measurement] = [:]
            for item in items {
                if let cached = measurements[item.id], cached.width == width,
                   cached.row == item.row, cached.configuration == item.configuration {
                    heights.append(cached.height)
                    retained[item.id] = cached
                } else {
                    let node = item.makeNode()
                    let size = node.layoutThatFits(Self.constraint(width)).size
                    let height = max(0.01, size.height)
                    heights.append(height)
                    nodes[item.id] = node
                    retained[item.id] = Measurement(
                        row: item.row, width: width, height: height, configuration: item.configuration
                    )
                }
            }
            measurements = retained
            let snapshot = ChatPlaygroundSnapshot(
                items: items, geometry: ChatListGeometry(ids: items.map(\.id), heights: heights),
                width: width, preparedNodes: nodes
            )
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func nodes(
        for items: [ChatPlaygroundItem], width: CGFloat,
        completion: @escaping ([String: ChatPlaygroundRowNode]) -> Void
    ) {
        queue.async {
            var nodes: [String: ChatPlaygroundRowNode] = [:]
            for item in items {
                let node = item.makeNode()
                _ = node.layoutThatFits(Self.constraint(width))
                nodes[item.id] = node
                // Deliver nearby rows without waiting for the whole preload
                // band. UIKit installation has a separate main-thread budget.
                if nodes.count == 4 {
                    let batch = nodes
                    DispatchQueue.main.async { completion(batch) }
                    nodes.removeAll(keepingCapacity: true)
                }
            }
            if !nodes.isEmpty {
                let batch = nodes
                DispatchQueue.main.async { completion(batch) }
            }
        }
    }

    static func constraint(_ width: CGFloat) -> ASSizeRange {
        ASSizeRange(
            min: CGSize(width: width, height: 0),
            max: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
    }
}

/// The Custom wrapper hosts a production cell, including its portal, media,
/// gestures and context source.
final class ChatPlaygroundRowNode: ASCellNode {
    let itemID: String
    let content: ASCellNode
    var onHeightChanged: ((ChatPlaygroundRowNode) -> Void)?

    init(id: String, content: ASCellNode) {
        self.itemID = id
        self.content = content
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASWrapperLayoutSpec(layoutElement: content)
    }

    override func calculatedLayoutDidChange() {
        super.calculatedLayoutDidChange()
        // Measurement also happens off-main before any view exists.
        guard isNodeLoaded else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onHeightChanged?(self)
        }
    }
}

#endif
