//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

final class RoomSpaceMembershipViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?

    private let roomId: String
    private let roomName: String
    private let roomAvatarURL: String?
    private let service: RoomSpaceMembershipService
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?

    private var memberships: [RoomSpaceMembership] = []
    private var loadingError: Error?
    private var isLoading = false
    private var operatingSpaceId: String?
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init(
        room: Room,
        roomListService: ZynaRoomListService,
        audioPlayer: AudioPlayerService? = nil
    ) {
        self.roomId = room.id()
        self.roomName = room.displayName()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyRoomSpaceLinkName ?? String(localized: "Group")
        self.roomAvatarURL = room.avatarUrl()
        self.service = RoomSpaceMembershipService(roomListService: roomListService)
        super.init(node: SettingsScreenNode())
        self.voicePlayerHost = audioPlayer.map {
            EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: $0)
        }
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
        operationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupGlassTopBar()
        setupVoicePlayerHost()
        loadMemberships()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voicePlayerHost?.refresh()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        voicePlayerHost?.layout()
        glassTopBar.updateLayout(in: view)
        updateTableInsets()
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
                action: { [weak self] in self?.onBack?() }
            ),
            .title(text: String(localized: "Storylines"), subtitle: nil),
            .circleButton(
                icon: AppIcon.link.template(size: 17, weight: .semibold),
                accessibilityLabel: String(localized: "Add to Storyline"),
                action: { [weak self] in self?.showAddToSpace() }
            )
        ]
    }

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
        node.voicePlayerView = voicePlayerHost?.accessibilityView
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

    private func loadMemberships() {
        loadTask?.cancel()
        isLoading = true
        loadingError = nil
        reloadTableAndRefreshGlass()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let memberships = try await service.loadMemberships(for: roomId)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    self.loadingError = nil
                    self.memberships = memberships
                    self.reloadTableAndRefreshGlass()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    self.loadingError = error
                    self.memberships = []
                    self.reloadTableAndRefreshGlass()
                }
            }
        }
    }

    private func presentActions(for membership: RoomSpaceMembership) {
        guard operatingSpaceId == nil else { return }
        let controller = RoomSpaceRelationshipActionsViewController(
            membership: membership,
            roomId: roomId,
            roomName: roomName,
            roomAvatarURL: roomAvatarURL
        )
        controller.onActionSelected = { [weak self] action, membership, completion in
            self?.perform(action, membership: membership, completion: completion)
        }

        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(controller, animated: true)
    }

    private func showAddToSpace() {
        guard operatingSpaceId == nil else { return }

        let viewModel = RoomAddToSpaceViewModel(
            roomId: roomId,
            roomName: roomName,
            service: service
        )
        let controller = RoomAddToSpaceViewController(viewModel: viewModel)
        controller.onBack = { [weak controller] in
            controller?.zynaNavigationController?.pop()
        }
        controller.onSpaceAdded = { [weak self, weak controller] _ in
            self?.loadMemberships()
            controller?.zynaNavigationController?.pop()
        }

        zynaNavigationController?.push(controller)
    }

    private func perform(
        _ action: RoomSpaceMembershipAction,
        membership: RoomSpaceMembership,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        operationTask?.cancel()
        operatingSpaceId = membership.id
        reloadTableAndRefreshGlass()

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.perform(action, membership: membership, roomId: roomId)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.operatingSpaceId = nil
                    self.loadMemberships()
                    completion?(.success(()))
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.operatingSpaceId = nil
                    self.reloadTableAndRefreshGlass()
                    if let completion {
                        completion(.failure(error))
                    } else {
                        self.showOperationError(error)
                    }
                }
            }
        }
    }

    private func reloadTableAndRefreshGlass() {
        tableView.reloadData()
        GlassService.shared.setNeedsCapture()
    }

    private func showOperationError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "Could Not Update Storyline Link"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private final class RoomSpaceRelationshipActionsViewController: UIViewController {

    enum Side {
        case space
        case chat

        var title: String {
            switch self {
            case .space:
                return String(localized: "Storyline side")
            case .chat:
                return String(localized: "Chat side")
            }
        }

        var explanation: String {
            switch self {
            case .space:
                return String(localized: "The Storyline lists this chat with m.space.child.")
            case .chat:
                return String(localized: "The chat points back to the Storyline with m.space.parent.")
            }
        }

        static func side(for action: RoomSpaceMembershipAction) -> Side {
            switch action {
            case .setSpaceSideLink, .removeSpaceSideLink:
                return .space
            case .setRoomSideLink, .removeRoomSideLink:
                return .chat
            }
        }
    }

    struct SideState {
        let isLinked: Bool
        let canEdit: Bool
        let action: RoomSpaceMembershipAction
        let isOperating: Bool
        let errorMessage: String?
    }

    var onActionSelected: ((
        RoomSpaceMembershipAction,
        RoomSpaceMembership,
        @escaping (Result<Void, Error>) -> Void
    ) -> Void)?

    private let membership: RoomSpaceMembership
    private let roomId: String
    private let roomName: String
    private let roomAvatarURL: String?
    private let heroView = RoomSpaceLinkHeroView()
    private weak var contentStack: UIStackView?
    private var didInstallHeroHeightConstraint = false
    private var visibleSpaceSideLinked: Bool
    private var visibleRoomSideLinked: Bool
    private var previousVisibleLinks: (space: Bool, room: Bool)?
    private var operatingAction: RoomSpaceMembershipAction?
    private var operatingSide: Side?
    private var failedSide: Side?
    private var operationErrorMessage: String?

    init(
        membership: RoomSpaceMembership,
        roomId: String,
        roomName: String,
        roomAvatarURL: String?
    ) {
        self.membership = membership
        self.roomId = roomId
        self.roomName = roomName
        self.roomAvatarURL = roomAvatarURL
        self.visibleSpaceSideLinked = membership.status.hasSpaceSide
        self.visibleRoomSideLinked = membership.status.hasRoomSide
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .appBG
        buildLayout()
    }

    private func buildLayout() {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24)
        ])

        contentStack = stack
        reloadContent()
    }

    private func reloadContent() {
        guard let stack = contentStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let heroView = linkHeroView()
        stack.addArrangedSubview(headerView())
        stack.addArrangedSubview(heroView)
        stack.setCustomSpacing(18, after: heroView)
        stack.addArrangedSubview(sideCard(side: .space, state: state(for: .space)))
        stack.addArrangedSubview(sideCard(side: .chat, state: state(for: .chat)))
    }

    private func linkHeroView() -> UIView {
        heroView.translatesAutoresizingMaskIntoConstraints = false
        heroView.apply(RoomSpaceLinkHeroView.Configuration(
            groupId: roomId,
            groupName: roomName,
            groupAvatarMxcURL: roomAvatarURL,
            spaceId: membership.id,
            spaceName: membership.displayName,
            spaceAvatarMxcURL: membership.avatarURL,
            hasSpaceSideLink: visibleSpaceSideLinked,
            hasRoomSideLink: visibleRoomSideLinked,
            canEditSpaceSide: membership.canEditSpaceSide,
            canEditRoomSide: membership.canEditRoomSide
        ))
        heroView.isAccessibilityElement = true
        heroView.accessibilityLabel = accessibilityLabelForHero()

        if !didInstallHeroHeightConstraint {
            heroView.heightAnchor.constraint(equalToConstant: 232).isActive = true
            didInstallHeroHeightConstraint = true
        }
        return heroView
    }

    private func accessibilityLabelForHero() -> String {
        switch (visibleSpaceSideLinked, visibleRoomSideLinked) {
        case (true, true):
            return String(localized: "Storyline and chat are linked in both directions.")
        case (true, false):
            if membership.canEditRoomSide {
                return String(localized: "Storyline links to this chat. The chat can confirm the return link.")
            }
            return String(localized: "Storyline links to this chat. The chat cannot confirm the return link.")
        case (false, true):
            if membership.canEditSpaceSide {
                return String(localized: "Chat links to this Storyline. The Storyline can add this chat.")
            }
            return String(localized: "Chat links to this Storyline. The Storyline cannot add this chat.")
        case (false, false):
            return String(localized: "Storyline and chat are not linked.")
        }
    }

    private var visibleStatusTitle: String {
        switch (visibleSpaceSideLinked, visibleRoomSideLinked) {
        case (true, true):
            return String(localized: "Linked")
        case (true, false):
            return String(localized: "Listed by Storyline")
        case (false, true):
            return String(localized: "Declared by Chat")
        case (false, false):
            return String(localized: "Unlinked")
        }
    }

    private var visibleStatusDetail: String {
        switch (visibleSpaceSideLinked, visibleRoomSideLinked) {
        case (true, true):
            return String(localized: "Both sides recognize this link.")
        case (true, false):
            return String(localized: "The Storyline shows this chat, but the chat does not confirm it.")
        case (false, true):
            return String(localized: "The chat points to this Storyline, but the Storyline does not show it.")
        case (false, false):
            return String(localized: "Neither side currently declares this link.")
        }
    }

    private var visibleStatusTintColor: UIColor {
        switch (visibleSpaceSideLinked, visibleRoomSideLinked) {
        case (true, true):
            return .systemTeal
        case (true, false):
            return .systemOrange
        case (false, true):
            return .systemBlue
        case (false, false):
            return .tertiaryLabel
        }
    }

    private func headerView() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8

        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.text = membership.displayName

        let statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.textColor = visibleStatusTintColor
        statusLabel.text = visibleStatusTitle

        let detailLabel = UILabel()
        detailLabel.font = .systemFont(ofSize: 15)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.text = visibleStatusDetail

        let modelLabel = UILabel()
        modelLabel.font = .systemFont(ofSize: 14)
        modelLabel.textColor = .tertiaryLabel
        modelLabel.numberOfLines = 0
        modelLabel.text = String(localized: "Matrix stores this as two independent links. They can disagree, so Zyna lets you edit each side explicitly.")

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(modelLabel)
        return stack
    }

    private func sideCard(side: Side, state: SideState) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let topStack = UIStackView()
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 10

        let labelsStack = UIStackView()
        labelsStack.axis = .vertical
        labelsStack.spacing = 3

        let titleLabel = UILabel()
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.text = side.title

        let detailLabel = UILabel()
        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.text = side.explanation

        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(detailLabel)
        labelsStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pill = statusPill(isLinked: state.isLinked)
        topStack.addArrangedSubview(labelsStack)
        topStack.addArrangedSubview(pill)

        let unavailableLabel = UILabel()
        unavailableLabel.font = .systemFont(ofSize: 13)
        unavailableLabel.textColor = .tertiaryLabel
        unavailableLabel.numberOfLines = 0
        unavailableLabel.text = state.canEdit
            ? nil
            : String(localized: "You do not have permission to edit this side.")
        unavailableLabel.isHidden = state.canEdit

        let displayedAction = state.isOperating ? (operatingAction ?? state.action) : state.action
        let buttonTitle: String
        if state.isOperating {
            buttonTitle = String(localized: "Applying change...")
        } else if state.errorMessage != nil {
            buttonTitle = String(localized: "Could not apply")
        } else {
            buttonTitle = state.action.title
        }
        var title = AttributedString(buttonTitle)
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = title
        configuration.baseForegroundColor = displayedAction.isDestructive ? .systemRed : AppColor.accent
        configuration.background.backgroundColor = displayedAction.isDestructive
            ? UIColor.systemRed.withAlphaComponent(state.canEdit ? 0.12 : 0.06)
            : AppColor.accent.withAlphaComponent(state.canEdit ? 0.14 : 0.06)
        configuration.background.cornerRadius = 12
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        configuration.showsActivityIndicator = state.isOperating
        configuration.activityIndicatorColorTransformer = UIConfigurationColorTransformer { _ in
            displayedAction.isDestructive ? .systemRed : AppColor.accent
        }

        let button = UIButton(configuration: configuration)
        let canTap = state.canEdit && operatingAction == nil
        button.isEnabled = state.canEdit
        button.isUserInteractionEnabled = canTap
        button.alpha = state.canEdit ? 1 : 0.45
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.beginOperation(state.action)
        }, for: .touchUpInside)

        contentStack.addArrangedSubview(topStack)
        contentStack.addArrangedSubview(unavailableLabel)
        contentStack.addArrangedSubview(button)
        button.accessibilityHint = state.errorMessage

        card.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])

        return card
    }

    private func beginOperation(_ action: RoomSpaceMembershipAction) {
        guard operatingAction == nil,
              let onActionSelected
        else { return }

        previousVisibleLinks = (visibleSpaceSideLinked, visibleRoomSideLinked)
        operatingAction = action
        operatingSide = Side.side(for: action)
        failedSide = nil
        operationErrorMessage = nil
        applyOptimisticState(for: action)
        reloadContent()

        onActionSelected(action, membership) { [weak self] result in
            self?.finishOperation(result)
        }
    }

    private func applyOptimisticState(for action: RoomSpaceMembershipAction) {
        switch action {
        case .setSpaceSideLink:
            visibleSpaceSideLinked = true
        case .setRoomSideLink:
            visibleRoomSideLinked = true
        case .removeSpaceSideLink:
            visibleSpaceSideLinked = false
        case .removeRoomSideLink:
            visibleRoomSideLinked = false
        }
    }

    private func finishOperation(_ result: Result<Void, Error>) {
        let completedSide = operatingSide
        operatingAction = nil
        operatingSide = nil

        switch result {
        case .success:
            previousVisibleLinks = nil
            operationErrorMessage = nil
            failedSide = nil
        case .failure(let error):
            if let previousVisibleLinks {
                visibleSpaceSideLinked = previousVisibleLinks.space
                visibleRoomSideLinked = previousVisibleLinks.room
            }
            self.previousVisibleLinks = nil
            operationErrorMessage = error.localizedDescription
            failedSide = completedSide
        }

        reloadContent()
    }

    private func statusPill(isLinked: Bool) -> UILabel {
        let label = PaddedLabel()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.text = isLinked ? String(localized: "Present") : String(localized: "Missing")
        label.textColor = isLinked ? .systemGreen : .systemOrange
        label.backgroundColor = isLinked
            ? UIColor.systemGreen.withAlphaComponent(0.14)
            : UIColor.systemOrange.withAlphaComponent(0.16)
        label.layer.cornerRadius = 10
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func state(for side: Side) -> SideState {
        switch side {
        case .space:
            let hasLink = visibleSpaceSideLinked
            return SideState(
                isLinked: hasLink,
                canEdit: membership.canEditSpaceSide,
                action: hasLink ? .removeSpaceSideLink : .setSpaceSideLink,
                isOperating: operatingSide == .space,
                errorMessage: failedSide == .space ? operationErrorMessage : nil
            )
        case .chat:
            let hasLink = visibleRoomSideLinked
            return SideState(
                isLinked: hasLink,
                canEdit: membership.canEditRoomSide,
                action: hasLink ? .removeRoomSideLink : .setRoomSideLink,
                isOperating: operatingSide == .chat,
                errorMessage: failedSide == .chat ? operationErrorMessage : nil
            )
        }
    }
}

private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}

private extension String {
    var nonEmptyRoomSpaceLinkName: String? {
        isEmpty ? nil : self
    }
}

extension RoomSpaceMembershipViewController: UITableViewDataSource {

    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isLoading || loadingError != nil || memberships.isEmpty ? 1 : memberships.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if isLoading {
            return messageCell(text: String(localized: "Loading Storylines..."))
        }

        if let loadingError {
            let cell = messageCell(text: String(localized: "Could Not Load Storylines"))
            cell.detailTextLabel?.text = loadingError.localizedDescription
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = .none
            return cell
        }

        guard !memberships.isEmpty else {
            return messageCell(text: String(localized: "No Storylines"))
        }

        let membership = memberships[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "MembershipCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "MembershipCell")

        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.textLabel?.text = membership.displayName
        cell.textLabel?.font = .systemFont(ofSize: 17)
        cell.detailTextLabel?.text = membership.status.title
        cell.detailTextLabel?.font = .systemFont(ofSize: 14)
        cell.detailTextLabel?.textColor = membership.status.tintColor
        cell.imageView?.image = AppIcon.link.rendered(
            size: 17,
            weight: .medium,
            color: membership.status.tintColor
        )
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default

        if operatingSpaceId == membership.id {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            cell.accessoryView = indicator
            cell.selectionStyle = .none
        }

        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(membership.displayName), \(membership.status.title)"
        cell.accessibilityHint = String(localized: "Shows Storyline link details")
        return cell
    }

    private func messageCell(text: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MessageCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "MessageCell")
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.textLabel?.text = text
        cell.textLabel?.font = .systemFont(ofSize: 17)
        cell.textLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = nil
        cell.imageView?.image = nil
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        return cell
    }
}

extension RoomSpaceMembershipViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isLoading,
              loadingError == nil,
              memberships.indices.contains(indexPath.row)
        else { return }

        let membership = memberships[indexPath.row]
        presentActions(for: membership)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

private extension RoomSpaceMembershipStatus {
    var tintColor: UIColor {
        switch self {
        case .linked:
            return .systemGreen
        case .listedBySpaceOnly:
            return .systemOrange
        case .declaredByRoomOnly:
            return .systemBlue
        }
    }
}
