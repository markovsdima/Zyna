//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class RoomDetailsViewController: ASDKViewController<RoomDetailsNode> {

    var onBack: (() -> Void)?
    var onSearchTapped: (() -> Void)?
    var onInviteMembersTapped: (() -> Void)?
    var onMembersTapped: (() -> Void)?

    private let room: Room
    private let memberCount: Int?
    private let glassTopBar = GlassTopBar()

    init(room: Room, memberCount: Int?) {
        self.room = room
        self.memberCount = memberCount
        super.init(node: RoomDetailsNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupGlassTopBar()

        node.onSearchTapped = { [weak self] in
            self?.onSearchTapped?()
        }

        node.onInviteTapped = { [weak self] in
            self?.onInviteMembersTapped?()
        }

        node.onMembersTapped = { [weak self] in
            self?.onMembersTapped?()
        }

        let name = room.displayName() ?? "Group"
        let avatarUrl = try? room.avatarUrl()
        node.update(name: name, memberCount: memberCount, avatarMxcUrl: avatarUrl)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
        let target = glassTopBar.coveredHeight + 24
        if abs(target - node.topInset) > 0.5 {
            node.topInset = target
            node.setNeedsLayout()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        node.bottomInset = max(view.safeAreaInsets.bottom + 16, 16)
        node.setNeedsLayout()
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = node.contentNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        let backIcon = AppIcon.chevronBackward.rendered(size: 17, weight: .semibold, color: AppColor.accent)
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .flexibleSpace
        ]
    }
}

// MARK: - Accessibility

extension RoomDetailsViewController: AccessibilityFocusProviding {
    /// First element VO focuses on after push: the back button.
    var initialAccessibilityFocus: UIView? {
        glassTopBar.accessibilityElementsInOrder.first
    }
}
