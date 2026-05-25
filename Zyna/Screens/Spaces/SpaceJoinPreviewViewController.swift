//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

private enum JoinPreviewEntity {
    case storyline
    case track
    case chat

    init(presentation: SpacePresentationKind) {
        switch presentation {
        case .storyline:
            self = .storyline
        case .track:
            self = .track
        }
    }

    var title: String {
        switch self {
        case .storyline:
            return String(localized: "Storyline")
        case .track:
            return String(localized: "Track")
        case .chat:
            return String(localized: "Chat")
        }
    }

    var showsContents: Bool {
        self != .chat
    }

    func metaText(for room: RoomModel) -> String {
        switch self {
        case .storyline, .track:
            return room.spaceMetaText
        case .chat:
            return String(localized: "Chat")
        }
    }

    func joinMessage(entityName: String) -> String {
        switch self {
        case .storyline, .track:
            return String(localized: "Join this \(entityName) to see its chats and nested spaces.")
        case .chat:
            return String(localized: "Join this \(entityName) to read and send messages.")
        }
    }
}

final class SpaceJoinPreviewViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?
    var onJoined: ((RoomModel) -> Void)?

    private enum Row {
        case access
        case members
        case contents
        case address

        var title: String {
            switch self {
            case .access: return String(localized: "Access")
            case .members: return String(localized: "Members")
            case .contents: return String(localized: "Contents")
            case .address: return String(localized: "Address")
            }
        }
    }

    private enum PrimaryAction {
        case open
        case join
        case knock
    }

    private struct ActionPresentation {
        let action: PrimaryAction?
        let title: String
        let message: String
        let isEnabled: Bool
    }

    private var space: RoomModel
    private let previewEntity: JoinPreviewEntity
    private let roomListService: ZynaRoomListService
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private let headerView = SpaceJoinPreviewHeaderView()
    private let footerView = SpaceJoinPreviewFooterView()

    private var operationTask: Task<Void, Never>?
    private var isOperating = false

    init(
        space: RoomModel,
        presentation: SpacePresentationKind = .track,
        roomListService: ZynaRoomListService
    ) {
        self.space = space
        self.previewEntity = JoinPreviewEntity(presentation: presentation)
        self.roomListService = roomListService
        super.init(node: SettingsScreenNode())
        hidesBottomBarWhenPushed = true
    }

    init(
        room: RoomModel,
        roomListService: ZynaRoomListService
    ) {
        self.space = room
        self.previewEntity = .chat
        self.roomListService = roomListService
        super.init(node: SettingsScreenNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        operationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupGlassTopBar()
        setupHeaderAndFooter()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        glassTopBar.updateLayout(in: view)
        updateTableInsets()
        updateHeaderFooterFrames()
    }

    private var metadata: SpaceRoomMetadata? {
        space.spaceMetadata
    }

    private var entityName: String {
        previewEntity.title
    }

    private var rows: [Row] {
        var rows: [Row] = [.access, .members]
        if previewEntity.showsContents {
            rows.append(.contents)
        }
        if metadata?.canonicalAlias != nil {
            rows.append(.address)
        }
        return rows
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .appBG
        tableView.separatorStyle = .singleLine
        tableView.contentInsetAdjustmentBehavior = .never
        view.addSubview(tableView)
        node.tableView = tableView
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = tableView
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        glassTopBar.items = [
            .circleButton(
                icon: AppIcon.chevronBackward.template(size: 17, weight: .semibold),
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.handleBackTapped() }
            ),
            .title(text: String(localized: "\(entityName) Preview"), subtitle: accessTitle)
        ]
    }

    private func setupHeaderAndFooter() {
        headerView.configure(space: space, entity: previewEntity)
        footerView.onPrimaryAction = { [weak self] in
            self?.performPrimaryAction()
        }
        configureFooter()
        tableView.tableHeaderView = headerView
        tableView.tableFooterView = footerView
    }

    private func updateTableInsets() {
        let top = glassTopBar.coveredHeight
        if abs(tableView.contentInset.top - top) > 0.5 {
            tableView.contentInset.top = top
            tableView.verticalScrollIndicatorInsets.top = top
        }
        let bottom = max(view.safeAreaInsets.bottom + 16, 16)
        if abs(tableView.contentInset.bottom - bottom) > 0.5 {
            tableView.contentInset.bottom = bottom
            tableView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    private func updateHeaderFooterFrames() {
        updateTableViewHeader(headerView)
        updateTableViewFooter(footerView)
    }

    private func updateTableViewHeader(_ header: UIView) {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let targetSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let height = header.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let frame = CGRect(x: 0, y: 0, width: width, height: ceil(height))
        guard header.frame != frame else { return }
        header.frame = frame
        tableView.tableHeaderView = header
    }

    private func updateTableViewFooter(_ footer: UIView) {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let targetSize = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let height = footer.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let frame = CGRect(x: 0, y: 0, width: width, height: ceil(height))
        guard footer.frame != frame else { return }
        footer.frame = frame
        tableView.tableFooterView = footer
    }

    private func configureFooter() {
        let presentation = actionPresentation
        footerView.configure(
            title: isOperating ? operationTitle(for: presentation.action) : presentation.title,
            message: presentation.message,
            isEnabled: !isOperating && presentation.isEnabled,
            isLoading: isOperating
        )
    }

    private var actionPresentation: ActionPresentation {
        switch metadata?.membership {
        case .joined:
            return ActionPresentation(
                action: .open,
                title: String(localized: "Open \(entityName)"),
                message: String(localized: "You are already a member of this \(entityName)."),
                isEnabled: true
            )
        case .invited:
            return ActionPresentation(
                action: .join,
                title: String(localized: "Accept Invite"),
                message: String(localized: "Accept the invite to open this \(entityName)."),
                isEnabled: true
            )
        case .knocked:
            return ActionPresentation(
                action: nil,
                title: String(localized: "Request Sent"),
                message: String(localized: "Your request to join this \(entityName) is waiting for approval."),
                isEnabled: false
            )
        case .banned:
            return ActionPresentation(
                action: nil,
                title: String(localized: "Unavailable"),
                message: String(localized: "You cannot join this \(entityName)."),
                isEnabled: false
            )
        case .left, .none:
            break
        }

        switch metadata?.joinRule {
        case .public, .none:
            return ActionPresentation(
                action: .join,
                title: String(localized: "Join \(entityName)"),
                message: previewEntity.joinMessage(entityName: entityName),
                isEnabled: true
            )
        case .restricted:
            return ActionPresentation(
                action: .join,
                title: String(localized: "Join \(entityName)"),
                message: String(localized: "Your membership allows you to join this \(entityName)."),
                isEnabled: true
            )
        case .knock:
            return ActionPresentation(
                action: .knock,
                title: String(localized: "Ask to Join"),
                message: String(localized: "Send a request to join this \(entityName)."),
                isEnabled: true
            )
        case .knockRestricted(let rules):
            let canJoin = hasLocalMembership(in: rules)
            return ActionPresentation(
                action: canJoin ? .join : .knock,
                title: canJoin ? String(localized: "Join \(entityName)") : String(localized: "Ask to Join"),
                message: canJoin
                    ? String(localized: "Your membership allows you to join this \(entityName).")
                    : String(localized: "Send a request to join this \(entityName)."),
                isEnabled: true
            )
        case .invite, .private:
            return ActionPresentation(
                action: nil,
                title: String(localized: "Invite Required"),
                message: String(localized: "You need an invite to join this \(entityName)."),
                isEnabled: false
            )
        case .custom(repr: _):
            return ActionPresentation(
                action: nil,
                title: String(localized: "Unavailable"),
                message: String(localized: "This \(entityName) uses an access rule Zyna cannot join directly."),
                isEnabled: false
            )
        }
    }

    private var accessTitle: String {
        switch metadata?.membership {
        case .invited:
            return String(localized: "Invited")
        case .knocked:
            return String(localized: "Request Sent")
        case .banned:
            return String(localized: "Unavailable")
        case .joined:
            return String(localized: "Joined")
        case .left, .none:
            break
        }

        switch metadata?.joinRule {
        case .public:
            return String(localized: "Public")
        case .restricted:
            return String(localized: "Restricted")
        case .knock, .knockRestricted:
            return String(localized: "Ask to join")
        case .invite, .private:
            return String(localized: "Invite only")
        case .custom:
            return String(localized: "Custom")
        case .none:
            return String(localized: "Joinable")
        }
    }

    private var accessDetail: String {
        switch metadata?.joinRule {
        case .public:
            return String(localized: "Anyone can join this \(entityName).")
        case .restricted:
            return String(localized: "Members of an authorized Storyline can join.")
        case .knock:
            return String(localized: "People can request access.")
        case .knockRestricted:
            return String(localized: "Authorized members can join; others can request access.")
        case .invite, .private:
            return String(localized: "Only invited people can join.")
        case .custom:
            return String(localized: "Custom Matrix access rule.")
        case .none:
            return String(localized: "Access details are not available.")
        }
    }

    private func operationTitle(for action: PrimaryAction?) -> String {
        switch action {
        case .open:
            return String(localized: "Opening...")
        case .join:
            return String(localized: "Joining...")
        case .knock:
            return String(localized: "Sending...")
        case .none:
            return String(localized: "Working...")
        }
    }

    private func hasLocalMembership(in rules: [AllowRule]) -> Bool {
        for rule in rules {
            guard case let .roomMembership(roomId) = rule else { continue }
            if roomListService.room(for: roomId)?.membership() == .joined {
                return true
            }
            if let client = MatrixClientService.shared.client,
               let room = try? client.getRoom(roomId: roomId),
               room.membership() == .joined {
                return true
            }
        }
        return false
    }

    private func performPrimaryAction() {
        guard !isOperating else { return }
        switch actionPresentation.action {
        case .open:
            onJoined?(space)
        case .join:
            joinRoom()
        case .knock:
            knockRoom()
        case .none:
            break
        }
    }

    private func handleBackTapped() {
        operationTask?.cancel()
        operationTask = nil
        onBack?()
    }

    private func joinRoom() {
        let request = joinRequest()
        let currentRoomModel = space
        let currentMetadata = metadata
        let roomListService = roomListService

        setOperating(true)
        operationTask?.cancel()
        operationTask = Task { [weak self, roomListService] in
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.finishOperation()
                    self.presentError(message: String(localized: "Matrix client is not ready."))
                }
                return
            }

            do {
                let room: Room
                if currentMetadata?.membership == .invited,
                   let invitedRoom = roomListService.room(for: currentRoomModel.id) {
                    try await invitedRoom.join()
                    room = invitedRoom
                } else {
                    room = try await client.joinRoomByIdOrAlias(
                        roomIdOrAlias: request.roomIdOrAlias,
                        serverNames: request.serverNames
                    )
                }
                _ = try? await client.awaitRoomRemoteEcho(roomId: room.id())
                let joinedRoomModel = await Self.joinedRoomModel(
                    currentRoomModel: currentRoomModel,
                    currentMetadata: currentMetadata,
                    joinedRoom: room,
                    client: client,
                    roomListService: roomListService
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.finishOperation()
                    self.onJoined?(joinedRoomModel)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.finishOperation()
                    self.presentError(message: error.localizedDescription)
                }
            }
        }
    }

    private func knockRoom() {
        let request = joinRequest()
        let knockedMetadata = metadata?.withMembership(.knocked)
        let entityName = entityName

        setOperating(true)
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let client = MatrixClientService.shared.client else {
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.finishOperation()
                    self.presentError(message: String(localized: "Matrix client is not ready."))
                }
                return
            }

            do {
                let room = try await client.knock(
                    roomIdOrAlias: request.roomIdOrAlias,
                    reason: nil,
                    serverNames: request.serverNames
                )
                _ = try? await client.awaitRoomRemoteEcho(roomId: room.id())
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    if let knockedMetadata {
                        self.space = self.space.withSpaceMetadata(knockedMetadata)
                    }
                    self.finishOperation()
                    self.tableView.reloadData()
                    self.configureFooter()
                    self.presentInfo(
                        title: String(localized: "Request Sent"),
                        message: String(localized: "Your request to join this \(entityName) was sent.")
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.finishOperation()
                    self.presentError(message: error.localizedDescription)
                }
            }
        }
    }

    private static func joinedRoomModel(
        currentRoomModel: RoomModel,
        currentMetadata: SpaceRoomMetadata?,
        joinedRoom: Room,
        client: Client,
        roomListService: ZynaRoomListService
    ) async -> RoomModel {
        let spaceService = await client.spaceService()
        let loadedSpaceRoom = try? await spaceService.getSpaceRoom(roomId: joinedRoom.id())
        let loadedMetadata = loadedSpaceRoom.map { SpaceRoomMetadata(spaceRoom: $0) }
        let metadata = (loadedMetadata ?? currentMetadata)?.withMembership(.joined)

        let name = loadedSpaceRoom?.displayName.nilIfEmpty
            ?? joinedRoom.displayName()?.nilIfEmpty
            ?? currentRoomModel.name
        let avatarURL = loadedSpaceRoom?.avatarUrl
            ?? joinedRoom.avatarUrl()
            ?? currentRoomModel.avatar.mxcAvatarURL

        if currentRoomModel.isSpace {
            _ = await roomListService.refreshSpaceChildren(for: joinedRoom.id())
        }
        return currentRoomModel
            .withSpaceProfile(name: name, avatarURL: avatarURL)
            .withSpaceMetadata(metadata)
    }

    private func joinRequest() -> (roomIdOrAlias: String, serverNames: [String]) {
        if let alias = metadata?.canonicalAlias, !alias.isEmpty {
            return (alias, [])
        }
        return (space.id, metadata?.via ?? [])
    }

    private func setOperating(_ operating: Bool) {
        isOperating = operating
        glassTopBar.subtitle = accessTitle
        tableView.reloadData()
        configureFooter()
    }

    private func finishOperation() {
        operationTask = nil
        setOperating(false)
    }

    private func presentError(message: String) {
        let alert = UIAlertController(
            title: String(localized: "Could Not Join \(entityName)"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func presentInfo(title: String, message: String) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

extension SpaceJoinPreviewViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "previewValue")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "previewValue")
        configureBaseCell(cell)
        cell.textLabel?.text = row.title
        cell.detailTextLabel?.text = detailText(for: row)
        return cell
    }

    private func detailText(for row: Row) -> String {
        switch row {
        case .access:
            return accessTitle
        case .members:
            guard let count = metadata?.joinedMembersCount else {
                return String(localized: "Unknown")
            }
            return String.localizedStringWithFormat(
                String(localized: "%lld members"),
                Int64(count)
            )
        case .contents:
            guard let count = metadata?.childrenCount else {
                return String(localized: "Unknown")
            }
            return String.localizedStringWithFormat(
                String(localized: "%lld children"),
                Int64(count)
            )
        case .address:
            return metadata?.canonicalAlias ?? String(localized: "Not Set")
        }
    }

    private func configureBaseCell(_ cell: UITableViewCell) {
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.selectionStyle = .none
        cell.accessoryType = .none
        cell.textLabel?.font = .systemFont(ofSize: 17)
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.font = .systemFont(ofSize: 14)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 2
        cell.contentView.alpha = isOperating ? 0.55 : 1
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        accessDetail
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

private final class SpaceJoinPreviewHeaderView: UIView {
    private enum Metrics {
        static let avatarSize = CGSize(width: 78, height: 78)
        static let avatarCornerRadius: CGFloat = 18
        static let avatarThumbSize = Int(avatarSize.width * ScreenConstants.scale)
    }

    private let containerView = UIView()
    private let avatarImageView = UIImageView()
    private let nameLabel = UILabel()
    private let topicLabel = UILabel()
    private let metaLabel = UILabel()
    private var avatarRevision: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .appBG
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(space: RoomModel, entity: JoinPreviewEntity) {
        nameLabel.text = space.name.isEmpty ? String(localized: "Untitled") : space.name
        topicLabel.text = space.spaceMetadata?.topic?.nilIfEmpty ?? String(localized: "No description")
        topicLabel.textColor = space.spaceMetadata?.topic?.nilIfEmpty == nil ? .tertiaryLabel : .secondaryLabel
        metaLabel.text = entity.metaText(for: space)
        configureAvatar(space.avatar)
    }

    private func setupViews() {
        containerView.backgroundColor = .secondarySystemGroupedBackground
        containerView.layer.cornerRadius = 14
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = Metrics.avatarCornerRadius
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        topicLabel.font = .systemFont(ofSize: 15)
        topicLabel.numberOfLines = 3
        topicLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .systemFont(ofSize: 13, weight: .medium)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(avatarImageView)
        containerView.addSubview(nameLabel)
        containerView.addSubview(topicLabel)
        containerView.addSubview(metaLabel)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            avatarImageView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 18),
            avatarImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            avatarImageView.widthAnchor.constraint(equalToConstant: Metrics.avatarSize.width),
            avatarImageView.heightAnchor.constraint(equalToConstant: Metrics.avatarSize.height),
            avatarImageView.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -18),

            nameLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),

            topicLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            topicLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            topicLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),

            metaLabel.topAnchor.constraint(equalTo: topicLabel.bottomAnchor, constant: 8),
            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -18)
        ])
    }

    private func configureAvatar(_ avatar: AvatarViewModel) {
        avatarRevision &+= 1
        let revision = avatarRevision
        avatarImageView.image = avatar.roundedRectImage(
            size: Metrics.avatarSize,
            cornerRadius: Metrics.avatarCornerRadius,
            fontSize: 24
        )

        guard let mxc = avatar.mxcAvatarURL else { return }
        if let cached = MediaCache.shared.cachedImage(forUrl: mxc, size: Metrics.avatarThumbSize) {
            avatarImageView.image = Self.roundedAvatarImage(cached, cacheKey: mxc)
            return
        }

        Task { [weak self] in
            guard let image = await MediaCache.shared.loadThumbnail(
                mxcUrl: mxc,
                size: Metrics.avatarThumbSize
            ) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.avatarRevision == revision else { return }
                self.avatarImageView.image = Self.roundedAvatarImage(image, cacheKey: mxc)
            }
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
}

private final class SpaceJoinPreviewFooterView: UIView {
    var onPrimaryAction: (() -> Void)?

    private let stackView = UIStackView()
    private let messageLabel = UILabel()
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .appBG
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, message: String, isEnabled: Bool, isLoading: Bool) {
        messageLabel.text = message
        button.setTitle(title, for: .normal)
        button.isEnabled = isEnabled
        button.alpha = isEnabled ? 1 : 0.55
        button.backgroundColor = isEnabled ? AppColor.accent : .tertiarySystemFill
        button.setTitleColor(isEnabled ? .white : .secondaryLabel, for: .normal)
        button.accessibilityValue = isLoading ? String(localized: "In progress") : nil
    }

    private func setupViews() {
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)

        stackView.addArrangedSubview(messageLabel)
        stackView.addArrangedSubview(button)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24)
        ])
    }

    @objc private func buttonTapped() {
        onPrimaryAction?()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
