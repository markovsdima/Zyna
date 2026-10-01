// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

@MainActor
protocol RoomProfileContentPage: AnyObject {
    var view: UIView { get }
    var scrollView: UIScrollView { get }
    var inset: CGFloat { get }
    var normalizedOffset: CGFloat { get }
    var isAdjusting: Bool { get }
    var isActive: Bool { get set }
    var headerHeight: CGFloat { get set }
    var tabsHeight: CGFloat { get set }
    var collapse: CGFloat { get set }
    var restorationAnchor: RoomProfileAnchor? { get set }
    var forceLoadIds: Set<String> { get set }
    var fullFileThreshold: UInt64 { get set }
    var onScroll: (() -> Void)? { get set }
    var onSelect: ((AttachmentItem, UIImage?, CGRect) -> Void)? { get set }
    var onShowInChat: ((AttachmentItem) -> Void)? { get set }
    var onLoad: (() -> Void)? { get set }
    var onRequestImage: ((AttachmentItem) -> Void)? { get set }
    var onAnchorRestored: ((CGFloat) -> Void)? { get set }
    var onNearEnd: ((Bool) -> Void)? { get set }
    var onContextInteractionChanged: ((Bool) -> Void)? { get set }
    func install()
    func layout(frame: CGRect, depth: CGFloat, bottomInset: CGFloat)
    func setPosition(depth: CGFloat)
    func captureAnchor() -> RoomProfileAnchor?
    func update(_ rows: [RoomProfileRow])
    func refreshTypography()
    func refreshImagePlans()
    func scrollToBeginning(animated: Bool)
    func stopScrollingToBeginning()
    func dismissContextMenu()
    func updateNearEnd()
}

extension RoomProfileFilePage: RoomProfileContentPage {
    var view: UIView { node.view }
}
