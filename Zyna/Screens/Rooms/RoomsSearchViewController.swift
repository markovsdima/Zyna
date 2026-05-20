//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

private enum RoomsSearchListItem {
    case header(String)
    case chat(RoomModel)
    case user(UserProfile)
    case publicRoom(PublicRoomSearchResult)
    case status(String)
}

final class RoomsSearchViewController: ASDKViewController<RoomsSearchOverlayNode>, ASTableDataSource, ASTableDelegate {

    var onOpenTarget: ((ChatOpenTarget) -> Void)?

    private let viewModel: RoomsUnifiedSearchViewModel
    private let localChatsProvider: (String) -> [RoomModel]
    private let resolveLocalChat: (RoomModel, @escaping (ChatOpenTarget) -> Void) -> Void
    private var items: [RoomsSearchListItem] = []
    private var cancellables = Set<AnyCancellable>()
    private weak var publicRoomPreviewController: PublicRoomPreviewViewController?
    private var didFocusSearch = false

    init(
        roomListService: ZynaRoomListService,
        localChatsProvider: @escaping (String) -> [RoomModel],
        resolveLocalChat: @escaping (RoomModel, @escaping (ChatOpenTarget) -> Void) -> Void
    ) {
        self.viewModel = RoomsUnifiedSearchViewModel(roomListService: roomListService)
        self.localChatsProvider = localChatsProvider
        self.resolveLocalChat = resolveLocalChat
        super.init(node: RoomsSearchOverlayNode())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        node.tableNode.dataSource = self
        node.tableNode.delegate = self
        node.tableNode.view.separatorStyle = .none
        node.tableNode.view.keyboardDismissMode = .onDrag
        node.tableNode.view.contentInsetAdjustmentBehavior = .never

        node.onQueryChanged = { [weak self] query in
            guard let self else { return }
            self.viewModel.update(
                query: query,
                localChats: self.localChatsProvider(query)
            )
        }
        node.onCancel = { [weak self] in
            self?.zynaNavigationController?.dismiss(animated: true)
        }

        viewModel.onSnapshotChanged = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        viewModel.onOpenTargetReady = { [weak self] target in
            self?.openTarget(target)
        }
        viewModel.onError = { [weak self] message in
            self?.publicRoomPreviewController?.setJoining(false)
            self?.showError(message)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didFocusSearch else { return }
        didFocusSearch = true
        node.focusSearch()
    }

    private func apply(_ snapshot: RoomsUnifiedSearchSnapshot) {
        items = Self.makeItems(from: snapshot)
        node.tableNode.reloadData()
    }

    private static func makeItems(from snapshot: RoomsUnifiedSearchSnapshot) -> [RoomsSearchListItem] {
        guard !snapshot.query.isEmpty else { return [] }

        var items: [RoomsSearchListItem] = []

        if !snapshot.localChats.isEmpty {
            items.append(.header(String(localized: "Chats")))
            items.append(contentsOf: snapshot.localChats.prefix(10).map { .chat($0) })
        }

        if !snapshot.users.isEmpty || snapshot.isSearchingPeople {
            items.append(.header(String(localized: "People")))
            if snapshot.users.isEmpty {
                items.append(.status(String(localized: "Searching...")))
            } else {
                items.append(contentsOf: snapshot.users.prefix(10).map { .user($0) })
            }
        }

        if !snapshot.publicRooms.isEmpty || snapshot.isSearchingRooms {
            items.append(.header(String(localized: "Public Rooms")))
            if snapshot.publicRooms.isEmpty {
                items.append(.status(String(localized: "Searching...")))
            } else {
                items.append(contentsOf: snapshot.publicRooms.prefix(20).map { .publicRoom($0) })
            }
        }

        if items.isEmpty {
            guard snapshot.query.count >= RoomsUnifiedSearchViewModel.minimumRemoteQueryLength else {
                return []
            }
            items.append(.status(snapshot.errorMessage ?? String(localized: "No results")))
        }

        return items
    }

    private func selectItem(_ item: RoomsSearchListItem) {
        switch item {
        case .header, .status:
            break
        case .chat(let chat):
            node.endSearchEditing()
            resolveLocalChat(chat) { [weak self] target in
                self?.openTarget(target)
            }
        case .user(let user):
            node.endSearchEditing()
            viewModel.openUser(user)
        case .publicRoom(let room):
            node.endSearchEditing()
            showPublicRoomPreview(room)
        }
    }

    private func showPublicRoomPreview(_ room: PublicRoomSearchResult) {
        let vc = PublicRoomPreviewViewController(
            publicRoom: room,
            isJoined: viewModel.joinedRoom(for: room) != nil
        )

        vc.onBack = { [weak vc] in
            vc?.zynaNavigationController?.pop()
        }
        vc.onJoinTapped = { [weak self, weak vc] in
            guard let self else { return }
            if let existingRoom = self.viewModel.joinedRoom(for: room) {
                vc?.setJoined(true)
                self.openTarget(.live(existingRoom))
                return
            }

            vc?.setJoining(true)
            self.viewModel.joinPublicRoom(room)
        }

        publicRoomPreviewController = vc
        zynaNavigationController?.push(vc)
    }

    private func openTarget(_ target: ChatOpenTarget) {
        publicRoomPreviewController?.setJoining(false)
        publicRoomPreviewController?.setJoined(true)
        let presenter = zynaNavigationController ?? self
        presenter.dismiss(animated: true) { [weak self] in
            self?.onOpenTarget?(target)
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Search Error"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        let presenter = zynaNavigationController?.topViewController ?? self
        presenter.present(alert, animated: true)
    }

    // MARK: - ASTableDataSource

    func numberOfSections(in tableNode: ASTableNode) -> Int {
        1
    }

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        guard items.indices.contains(indexPath.row) else { return { ASCellNode() } }
        let item = items[indexPath.row]
        return {
            switch item {
            case .header(let title):
                return RoomsSearchHeaderCellNode(title: title)
            case .chat(let chat):
                return RoomsCellNode(chat: chat)
            case .user(let user):
                return RoomsSearchResultCellNode(user: user)
            case .publicRoom(let room):
                return RoomsSearchResultCellNode(publicRoom: room)
            case .status(let text):
                return RoomsSearchStatusCellNode(text: text)
            }
        }
    }

    // MARK: - ASTableDelegate

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        guard items.indices.contains(indexPath.row) else { return }
        selectItem(items[indexPath.row])
    }
}
