// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

/// Stable route identity. A suspended route holds state, never a timeline,
/// message window, Texture collection, or a closure capturing the old chat.
final class ChatRouteViewController: UIViewController, NavigationResidentScreen {
    let roomIdentifier: String
    private let makeChat: (ChatNavigationState?) -> ChatViewController?
    private(set) var chat: ChatViewController?
    private var savedState: ChatNavigationState?
    private var contentVisible = false
    private var wasAttached = false
    private var pendingForward: ChatMessage?

    init(roomID: String, makeChat: @escaping (ChatNavigationState?) -> ChatViewController?) {
        roomIdentifier = roomID
        self.makeChat = makeChat
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var childForStatusBarStyle: UIViewController? { chat }
    override var childForHomeIndicatorAutoHidden: UIViewController? { chat }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .appBG
        materializeContent()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { wasAttached = true }
        else if wasAttached { discardContent() }
    }

    func materializeContent() {
        guard chat == nil, let controller = makeChat(savedState) else { return }
        chat = controller
        savedState = nil
        // A warm route must be hidden before mounting its view, including
        // when restoring inside an already attached wrapper.
        controller.setNavigationContentVisible(contentVisible)
        addChild(controller)
        loadViewIfNeeded()
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        if let pendingForward {
            controller.setPendingForward(pendingForward)
            self.pendingForward = nil
        }
    }

    func setPendingForward(_ message: ChatMessage) {
        if let chat { chat.setPendingForward(message) }
        else { pendingForward = message }
    }

    func releaseContent() {
        guard let chat, !contentVisible else { return }
        savedState = chat.captureNavigationState()
        discardContent()
    }

    private func discardContent() {
        guard let chat else { return }
        chat.finishNavigationSession()
        chat.willMove(toParent: nil)
        chat.viewIfLoaded?.removeFromSuperview()
        chat.removeFromParent()
        self.chat = nil
    }

    func setContentVisible(_ visible: Bool) {
        contentVisible = visible
        chat?.setNavigationContentVisible(visible)
    }
}

extension ZynaNavigationController {
    /// Profile actions and forwarding share the same room identity policy.
    @discardableResult
    func returnToChat(roomID: String, animated: Bool = true, forward: ChatMessage? = nil) -> Bool {
        guard let existing = stack.last(where: { $0.chatRoomIdentifier == roomID }) else { return false }
        pop(to: existing, animated: animated) { [weak existing] in
            if let forward { existing?.materializedChat()?.setPendingForward(forward) }
        }
        return true
    }
}

extension UIViewController {
    var chatRoomIdentifier: String? {
        (self as? ChatRouteViewController)?.roomIdentifier ?? (self as? ChatViewController)?.roomIdentifier
    }

    var residentChat: ChatViewController? {
        (self as? ChatRouteViewController)?.chat ?? (self as? ChatViewController)
    }

    func materializedChat() -> ChatViewController? {
        (self as? ChatRouteViewController)?.materializeContent()
        return residentChat
    }
}
