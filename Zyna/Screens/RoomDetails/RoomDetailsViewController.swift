//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class RoomDetailsViewController: ASDKViewController<RoomDetailsNode> {

    var onSearchTapped: (() -> Void)?
    var onInviteMembersTapped: (() -> Void)?

    private let room: Room
    private let memberCount: Int?

    init(room: Room, memberCount: Int?) {
        self.room = room
        self.memberCount = memberCount
        super.init(node: RoomDetailsNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        node.onSearchTapped = { [weak self] in
            self?.onSearchTapped?()
        }

        node.onInviteTapped = { [weak self] in
            self?.onInviteMembersTapped?()
        }

        let name = room.displayName() ?? "Group"
        let avatarUrl = try? room.avatarUrl()
        node.update(name: name, memberCount: memberCount, avatarMxcUrl: avatarUrl)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        node.topInset = view.safeAreaInsets.top + 24
        node.bottomInset = max(view.safeAreaInsets.bottom + 16, 16)
        node.setNeedsLayout()
    }
}
