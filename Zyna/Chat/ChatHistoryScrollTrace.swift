//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

#if DEBUG
import AsyncDisplayKit
import UIKit

/// Temporary viewport diagnostics. Enable with CHAT_PAGING_TRACE=1 in
/// the scheme's environment. No message content or identifiers are logged.
final class ChatHistoryScrollTrace {
    static let enabled = ProcessInfo.processInfo.environment["CHAT_PAGING_TRACE"] == "1"
    private let log = ScopedLog(.historyScroll, prefix: "CHATPAGING")
    private let started = enabled ? CACurrentMediaTime() : 0
    private var sequence = 0
    private var lastScrollTime: CFTimeInterval = 0
    private var lastOffset: CGFloat?
    private var scrollUntil: CFTimeInterval = 0
    private var remainingLines = 350

    struct Anchor {
        weak var node: ASCellNode?
        let row: Int
        let y: CGFloat
    }

    struct Batch {
        let id: Int
        let time: CFTimeInterval
        let anchors: [Anchor]
    }

    init() {
        if Self.enabled { LogConfig.enabled.insert(.historyScroll) }
    }

    func event(_ label: @autoclosure () -> String, table: ChatMessageList) {
        guard Self.enabled else { return }
        emit("\(label()) \(state(table))")
    }

    func beginBatch(_ update: TableUpdate, origin: MessageWindowChangeOrigin,
                    table: ChatMessageList, live: Bool, pinned: Bool, forcePin: Bool,
                    animated: Bool) -> Batch? {
        guard Self.enabled,
              case let .batch(deletions, insertions, moves, updates, _) = update else { return nil }
        sequence += 1
        let now = CACurrentMediaTime()
        scrollUntil = now + 1
        // Read the committed view map, not Texture's future datasource map.
        let visible = table.committedVisiblePaths.sorted()
        let anchors = visible.prefix(4).map { indexPath in
            Anchor(node: table.committedNode(at: indexPath), row: indexPath.row,
                   y: screenY(table, indexPath))
        }
        let reloaded = Set(updates.map(\.row))
        let deleted = Set(deletions.map(\.row))
        emit("batch#\(sequence) begin origin=\(origin.compactDescription) live=\(live) pinned=\(pinned) force=\(forcePin) "
             + "animated=\(animated) ins=\(rows(insertions)) del=\(rows(deletions)) "
             + "reload=\(rows(updates)) moves=\(moves.count) "
             + "anchors=\(anchors.map { "\($0.row):reload=\(reloaded.contains($0.row)):delete=\(deleted.contains($0.row))" }) "
             + state(table))
        return Batch(id: sequence, time: now, anchors: anchors)
    }

    func endBatch(_ batch: Batch?, table: ChatMessageList, phase: String) {
        guard Self.enabled, let batch else { return }
        let anchors = batch.anchors.map { anchor -> String in
            guard let node = anchor.node,
                  let path = table.committedIndexPath(for: node) else { return "\(anchor.row):lost" }
            return "\(anchor.row)->\(path.row):dy=\(f(screenY(table, path) - anchor.y))"
        }.joined(separator: ",")
        emit("batch#\(batch.id) \(phase) elapsed=\(f((CACurrentMediaTime() - batch.time) * 1000))ms "
             + "anchors=[\(anchors)] \(state(table))")
    }

    func didScroll(_ table: ChatMessageList) {
        guard Self.enabled else { return }
        let now = CACurrentMediaTime()
        let offset = table.contentOffset.y
        let delta = lastOffset.map { offset - $0 } ?? 0
        lastOffset = offset
        guard now < scrollUntil,
              now - lastScrollTime >= 0.1 || abs(delta) > table.bounds.height / 2 else { return }
        lastScrollTime = now
        emit("scroll delta=\(f(delta)) \(state(table))")
    }

    private func state(_ table: ChatMessageList) -> String {
        let view = table.view
        let visible = table.committedVisiblePaths
        return "offset=\(f(view.contentOffset.y)) size=\(f(view.contentSize.height)) "
            + "height=\(f(view.bounds.height)) inset=\(f(view.adjustedContentInset.top)),\(f(view.adjustedContentInset.bottom)) "
            + "visible=\(rows(visible)) "
            + "drag=\(view.isDragging) decel=\(view.isDecelerating) "
            + "pan=\(f(view.panGestureRecognizer.translation(in: view).y)) "
            + "velocity=\(f(view.panGestureRecognizer.velocity(in: view).y))"
    }

    private func screenY(_ list: ChatMessageList, _ path: IndexPath) -> CGFloat {
        list.view.convert(list.committedRect(at: path), to: list.view.window).minY
    }

    private func rows(_ paths: [IndexPath]) -> String {
        let sorted = paths.map(\.row).sorted()
        guard let first = sorted.first, let last = sorted.last else { return "0" }
        return "\(sorted.count)[\(first)...\(last)]"
    }

    private func f(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }

    private func emit(_ message: String) {
        guard remainingLines > 0 else { return }
        remainingLines -= 1
        log("+\(f((CACurrentMediaTime() - started) * 1000))ms \(message)")
        if remainingLines == 0 { log("Trace limit reached; reopen the chat to record again.") }
    }
}
#endif
