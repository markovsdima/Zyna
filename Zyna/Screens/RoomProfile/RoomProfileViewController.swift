// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import Combine
import MatrixRustSDK

/// Room identity and actions above independently positioned content pages.
final class RoomProfileViewController: ASDKViewController<ASDisplayNode>, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onBack: (() -> Void)?
    var onInformation: (() -> Void)?
    var onLegacyAttachments: (() -> Void)?
    var onAction: ((RoomProfileAction) -> Void)?
    var onShowInChat: ((String, ChatCatalogTarget) async throws -> PreparedPollNavigation)?
    var onOpenMediaImage: ((RoomMediaDatabase, AttachmentItem, CGRect) async throws -> Void)?

    private let model: RoomAttachmentsViewModel?
    private let personModel: PersonProfileViewModel?
    private let blockingFactory: (String) -> UserBlockingViewModel?
    private var blocking: UserBlockingViewModel?
    private var blockingObservations = Set<AnyCancellable>()
    private let actions: RoomAttachmentsActions
    private let room: Room?
    private let titleText: String
    private let profileModel: RoomProfileViewModel?
    private let pinnedModel: RoomPinnedMessagesModel?
    var roomIdentifier: String? { profileModel?.snapshot.roomID }
    private let linkSharing = MatrixLinkSharing.forCurrentSession()
    private let header: RoomProfileHeaderNode
    private let contentNode = ASDisplayNode()
    private weak var sharedPanScrollView: UIScrollView?
    private let avatarView = RoomProfileAvatarView()
    private let avatarLoader: @Sendable (String, Int) async -> UIImage?
    private let avatarDragTranslation: (UIScrollView, UIView) -> CGFloat
    private var hasAvatarPhoto = false
    private var avatarDrag: RoomProfileAvatarDrag?
    private var pendingAvatarSnap: CGFloat?
    private var avatarAnimation: DisplayLinkToken?
    private var avatarAnimationTarget: CGFloat?
    private var pagingAvatarTarget: CGFloat?
    private var avatarAnimationGeneration = 0
    private var largeAvatarTask: Task<Void, Never>?
    private var requestedAvatarPixels = 0
    private var loadedAvatarPixels = 0
    private lazy var avatarHaptic = UIImpactFeedbackGenerator(style: .soft)
    private lazy var avatarTap = UITapGestureRecognizer(target: self, action: #selector(toggleAvatar))
    private let pager = RoomProfilePagerScrollView()
    private lazy var fpsBooster = ScrollFPSBooster(hostView: pager)
    private let bar = UIView()
    private let compactTitle = UILabel()
    private let compactAvatar = UIImageView()
    private let backButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let navigationProgress = UIActivityIndicatorView(style: .medium)
    private let topButton = UIButton(type: .system)
    private let tabs = UISegmentedControl(items: [String(localized: "Media"), String(localized: "Files")])
    private let tabBackground = UIView()
    private var state = RoomProfileScrollState()
    private var sections: [RoomProfileScrollState.Section] = [.media, .files]
    private var keepsPinnedSection = false
    private var pages: [RoomProfileScrollState.Section: any RoomProfileContentPage] = [:]
    private let mediaCatalog: RoomMediaCatalog
    private var mediaColumns = 3
    var mediaGrid: RoomMediaGrid? { pages[.media] as? RoomMediaGrid }
    private var anchors: [RoomProfileScrollState.Section: RoomProfileAnchor] = [:]
    private var catalog: [RoomProfileScrollState.Section: [RoomProfileRow]] = [:]
    private var lastFooter: [RoomProfileScrollState.Section: RoomProfileRow] = [:]
    private let projectionQueue = DispatchQueue(label: "zyna.profile.catalog", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?
    private var avatarTask: Task<Void, Never>?
    private struct AvatarIdentity: Equatable {
        let id: String
        let title: String
        let url: String?
    }
    private var avatarIdentity: AvatarIdentity?
    private struct MenuState: Equatable {
        let snapshot: RoomProfileSnapshot
        let notifications: RoomNotificationSettings?
        let loading: Bool
        let saving: Bool
        let hasNotificationError: Bool
        let hasInformationError: Bool
        let preparingLink: Bool
    }
    var onReportRoom: (() -> Void)? {
        didSet { renderedMenuState = nil; if isViewLoaded { updateProfileMenus() } }
    }
    private var renderedMenuState: MenuState?
    private struct PersonMenuState: Equatable {
        let snapshot: PersonProfileSnapshot
        let performingAction: Bool
        let hasProfileError: Bool
        let isBlocked: Bool?
        let savingBlock: Bool
        let canChangeBlock: Bool
        let hasBlockError: Bool
        let preparingLink: Bool
    }
    private var renderedPersonMenuState: PersonMenuState?
    private var navigationTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var playerHost: EmbeddedVoiceTopPlayerHost?
    private var attached = false
    private var hasBegunAppearance = false
    private var layingOut = false
    private var previousWidth: CGFloat = 0
    private var isPresentingError = false
    private let initiallyHasPinnedMessages: Bool
    private var tabHeight: CGFloat { personModel == nil ? 48 : 0 }
    private struct HeaderGeometry: Equatable {
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
        let collapse: CGFloat
        let expansion: CGFloat
    }
    private var renderedHeaderGeometry: HeaderGeometry?

    init(room: Room?, title: String, subtitle: String, model: RoomAttachmentsViewModel?,
         actions: RoomAttachmentsActions, audioPlayer: AudioPlayerService? = nil, mediaCatalog: RoomMediaCatalog? = nil,
         profileModel: RoomProfileViewModel? = nil,
         pinnedModel: RoomPinnedMessagesModel? = nil,
         initiallyHasPinnedMessages: Bool = false,
         initialSection: RoomProfileScrollState.Section = .media,
         personModel: PersonProfileViewModel? = nil,
         blockingFactory: ((String) -> UserBlockingViewModel?)? = nil,
         avatarLoader: @escaping @Sendable (String, Int) async -> UIImage? = { mxc, pixels in
             await RoomProfileAvatarImageLoader.load(mxc, pixels)
         },
         avatarDragTranslation: @escaping (UIScrollView, UIView) -> CGFloat = { scrollView, view in
             scrollView.panGestureRecognizer.translation(in: view).y
         }) {
        self.room = room
        self.titleText = title
        self.model = model
        self.personModel = personModel
        self.blockingFactory = blockingFactory ?? UserBlockingViewModel.currentSessionFactory()
        self.actions = actions
        self.profileModel = profileModel
        self.pinnedModel = pinnedModel
        self.initiallyHasPinnedMessages = initiallyHasPinnedMessages
        if pinnedModel != nil, initialSection == .pinned || initiallyHasPinnedMessages { sections.append(.pinned) }
        if sections.contains(initialSection) {
            state.beginTransition()
            state.finishTransition(at: initialSection)
        }
        keepsPinnedSection = initialSection == .pinned
        self.avatarLoader = avatarLoader
        self.avatarDragTranslation = avatarDragTranslation
        self.mediaCatalog = mediaCatalog ?? RoomMediaCatalog()
        header = RoomProfileHeaderNode(title: title, subtitle: subtitle)
        super.init(node: ASDisplayNode())
        node.backgroundColor = .appBG
        hidesBottomBarWhenPushed = true
        if let audioPlayer { playerHost = EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: audioPlayer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init(personModel: PersonProfileViewModel, audioPlayer: AudioPlayerService? = nil) {
        self.init(room: nil, title: personModel.snapshot.title, subtitle: personModel.snapshot.userID,
            model: nil, actions: .none, audioPlayer: audioPlayer, personModel: personModel)
    }

    deinit {
        startTask?.cancel(); avatarTask?.cancel(); largeAvatarTask?.cancel()
        navigationTask?.cancel(); imageTask?.cancel(); avatarAnimation?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        node.addSubnode(contentNode)
        contentNode.view.addSubview(pager)
        contentNode.addSubnode(header)
        contentNode.view.addSubview(avatarView)
        avatarView.onActivate = { [weak self] in self?.toggleAvatar() }
        avatarTap.delegate = self
        avatarTap.cancelsTouchesInView = false
        view.addGestureRecognizer(avatarTap)
        header.onAction = { [weak self] in self?.perform($0) }
        header.onHeightChanged = { [weak self] in self?.view.setNeedsLayout() }
        contentNode.view.addSubview(tabBackground)
        tabBackground.addSubview(tabs)
        view.addSubview(bar)
        [compactAvatar, compactTitle, backButton, moreButton, navigationProgress].forEach { bar.addSubview($0) }
        contentNode.view.addSubview(topButton)
        bar.backgroundColor = .appBG
        tabBackground.backgroundColor = .appBG
        pager.delegate = self
        pager.canStartBackFromAnywhere = { [weak self] in
            guard let self else { return false }
            return self.state.selected == self.sections.first && self.state.transition == nil
        }
        pager.isPagingEnabled = true
        pager.isDirectionalLockEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.bounces = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.accessibilityIdentifier = "profile.pager"
        pager.isScrollEnabled = personModel == nil
        tabBackground.isHidden = personModel != nil
        rebuildTabs()
        tabs.accessibilityIdentifier = "profile.sections"
        tabs.addTarget(self, action: #selector(selectTab), for: .valueChanged)
        compactTitle.text = titleText
        compactTitle.font = .preferredFont(forTextStyle: .headline)
        compactTitle.adjustsFontForContentSizeCategory = true
        compactTitle.lineBreakMode = .byTruncatingTail
        compactAvatar.contentMode = .scaleAspectFill
        compactAvatar.layer.cornerRadius = 16
        compactAvatar.clipsToBounds = true
        backButton.setImage(AppIcon.chevronBackward.rendered(color: .label), for: .normal)
        backButton.accessibilityLabel = String(localized: "Back")
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        moreButton.setImage(AppIcon.ellipsis.template(), for: .normal)
        moreButton.accessibilityLabel = String(localized: "More", table: "RoomProfile")
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIAction(title: String(localized: "Room Details")) { [weak self] _ in self?.onInformation?() },
            UIAction(title: String(localized: "Attachments")) { [weak self] _ in self?.onLegacyAttachments?() }
        ])
        topButton.setImage(AppIcon.chevronUp.rendered(color: .systemBlue), for: .normal)
        topButton.backgroundColor = .secondarySystemBackground
        topButton.layer.cornerRadius = 24
        topButton.layer.shadowOpacity = 0.12
        topButton.layer.shadowRadius = 8
        topButton.accessibilityLabel = String(localized: "Scroll to top", table: "RoomProfile")
        topButton.accessibilityIdentifier = "profile.scrollToTop"
        topButton.addTarget(self, action: #selector(scrollToBeginning), for: .touchUpInside)
        playerHost?.install()
        playerHost?.onVisibilityChanged = { [weak self] in self?.view.setNeedsLayout() }
        ensurePage(state.selected)
        bind()
        bindProfile()
        bindSharing()
        bindPinned()
        startAttachmentsIfNeeded()
        NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)
            .sink { [weak self] _ in
                self?.header.updateTypography()
                self?.pages.values.forEach { $0.refreshTypography() }
                self?.view.setNeedsLayout()
            }.store(in: &cancellables)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent != nil { attached = true }
        else if attached {
            startTask?.cancel()
            avatarTask?.cancel()
            largeAvatarTask?.cancel()
            stopAvatarAnimation(finish: true)
            model?.stop()
            profileModel?.stop()
            pinnedModel?.stop()
            personModel?.stop()
            blocking?.stop()
            mediaCatalog.stop()
            cancellables.removeAll()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pages[state.selected]?.isActive = true
        updateSharedPan()
        loadLargeAvatarIfNeeded(retry: true)
        playerHost?.refresh()
        profileModel?.refreshNotifications()
        // Binding starts the first reads. Refresh only when returning so the
        // initial appearance does not cancel and repeat those requests.
        if hasBegunAppearance {
            personModel?.refresh()
            blocking?.refresh()
        }
        hasBegunAppearance = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showProfileError()
        showPersonError()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        linkSharing.cancel()
        settleInterruptedAvatar()
        stopAvatarAnimation(finish: true)
        pages.values.forEach { $0.dismissContextMenu(); $0.isActive = false }
        sharedPanScrollView?.panGestureRecognizer.isEnabled = false
        fpsBooster.stop()
        navigationTask?.cancel()
        imageTask?.cancel()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        guard state.transition == nil else { return }
        for section in RoomProfileScrollState.Section.allCases where section != state.selected {
            guard let page = pages.removeValue(forKey: section) else { continue }
            anchors[section] = page.captureAnchor()
            page.isActive = false
            page.updateNearEnd()
            page.view.removeFromSuperview()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        let width = view.bounds.width
        contentNode.frame = view.bounds
        let top = view.safeAreaInsets.top + 48
        let measured = header.layoutThatFits(ASSizeRange(min: CGSize(width: width, height: 0),
            max: CGSize(width: width, height: .greatestFiniteMagnitude))).size.height
        let height = max(208, measured)
        let expansion = hasAvatarPhoto ? RoomProfileAvatarGeometry.expansionHeight(width: width) : 0
        if state.headerHeight != height + expansion || state.avatarExpansionHeight != expansion {
            settleInterruptedAvatar()
            stopAvatarAnimation(finish: true)
            state.resizeHeader(to: height, avatarExpansionHeight: expansion)
        }
        if width != previousWidth, state.transition != nil {
            fpsBooster.stop()
            state.finishTransition(at: state.selected)
            for (section, page) in pages { page.isActive = section == state.selected }
            updateSharedPan()
        }
        pager.frame = CGRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top))
        pager.contentSize = CGSize(width: width * CGFloat(personModel == nil ? sections.count : 1), height: pager.bounds.height)
        if width != previousWidth { pager.contentOffset.x = width * CGFloat(sections.firstIndex(of: state.selected) ?? 0); previousWidth = width }
        bar.frame = CGRect(x: 0, y: 0, width: width, height: top)
        backButton.frame = CGRect(x: 8, y: top - 48, width: 44, height: 44)
        moreButton.frame = CGRect(x: width - 52, y: top - 48, width: 44, height: 44)
        navigationProgress.frame = moreButton.frame
        compactAvatar.frame = CGRect(x: 58, y: top - 42, width: 32, height: 32)
        compactTitle.frame = CGRect(x: 100, y: top - 48, width: max(0, width - 158), height: 44)
        topButton.frame = CGRect(x: width - 64, y: view.bounds.height - view.safeAreaInsets.bottom - 64, width: 48, height: 48)
        for (section, page) in pages {
            guard let index = sections.firstIndex(of: section) else { continue }
            page.headerHeight = state.headerHeight
            page.avatarExpansionHeight = state.avatarExpansionHeight
            page.tabsHeight = tabHeight
            page.collapse = state.collapse
            page.layout(frame: CGRect(x: width * CGFloat(index), y: 0, width: width, height: pager.bounds.height),
                        depth: state.depth(for: section), bottomInset: view.safeAreaInsets.bottom)
        }
        renderHeader()
        loadLargeAvatarIfNeeded()
        playerHost?.layout()
    }

    private func bind() {
        guard let model else { return }
        let usesPagedMedia = model.usesPagedMedia
        model.$media.combineLatest(model.$files)
            .receive(on: projectionQueue)
            .map { media, files in (usesPagedMedia ? [] : RoomProfileRow.rows(groups: media), RoomProfileRow.rows(groups: files)) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] media, files in
                guard let self else { return }
                self.catalog = [.media: media, .files: files]
                self.updatePages(catalogChanged: true)
            }.store(in: &cancellables)
        model.objectWillChange
            .debounce(for: .milliseconds(20), scheduler: RunLoop.main)
            .sink { [weak self] in self?.updatePages(); self?.showDownloadError() }
            .store(in: &cancellables)
        model.$forceLoadIds.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] ids in
            self?.pages.values.forEach { $0.forceLoadIds = ids; $0.refreshImagePlans() }
        }.store(in: &cancellables)
    }

    private func startAttachmentsIfNeeded() {
        guard state.selected != .pinned, startTask == nil, let model else { return }
        model.tab = state.selected == .media ? .media : .files
        startTask = Task { await model.start() }
    }

    private func bindPinned() {
        guard let pinnedModel else { return }
        pinnedModel.objectWillChange.debounce(for: .milliseconds(20), scheduler: RunLoop.main).sink { [weak self] in
            self?.updatePinnedPage()
            self?.updatePinnedSection()
        }.store(in: &cancellables)
        pinnedModel.start()
    }

    private func rebuildTabs() {
        tabs.removeAllSegments()
        for (index, section) in sections.enumerated() {
            let title: String
            switch section {
            case .media: title = String(localized: "Media")
            case .files: title = String(localized: "Files")
            case .pinned: title = String(localized: "Pinned", table: "RoomProfile")
            }
            tabs.insertSegment(withTitle: title, at: index, animated: false)
        }
        tabs.selectedSegmentIndex = sections.firstIndex(of: state.selected) ?? 0
    }

    private func updatePinnedSection() {
        guard let pinnedModel, state.transition == nil, tabs.isEnabled else { return }
        let visible = keepsPinnedSection || state.selected == .pinned
            || (initiallyHasPinnedMessages && pinnedModel.isLoading)
            || pinnedModel.loadError != nil || !pinnedModel.items.isEmpty
        let next: [RoomProfileScrollState.Section] = visible ? [.media, .files, .pinned] : [.media, .files]
        guard sections != next else { return }
        sections = next
        pages[.pinned]?.view.isHidden = !visible
        rebuildTabs()
        view.setNeedsLayout()
    }

    private func updatePinnedPage() {
        guard let pinnedModel, let page = pages[.pinned] else { return }
        let items = pinnedModel.items, loading = pinnedModel.isLoading, error = pinnedModel.loadError
        projectionQueue.async { [weak page] in
            var rows = items.map { item in
                RoomProfileRow(id: item.eventId, title: item.title,
                    detail: item.isUnpinning ? String(localized: "Unpinning…", table: "RoomProfile")
                        : item.unpinError ?? item.subtitle,
                    item: nil, isHeader: false, isAction: false, pinned: item)
            }
            if loading || error != nil || items.isEmpty {
                rows.append(RoomProfileRow(id: "pinned.status",
                    title: error != nil ? String(localized: "Try Again")
                        : (loading ? String(localized: "Loading") : String(localized: "No pinned messages")),
                    detail: error, item: nil, isHeader: false, isAction: error != nil))
            }
            let result = rows
            DispatchQueue.main.async { page?.update(result) }
        }
    }

    private func confirmUnpin(_ eventID: String) {
        guard let pinnedModel, pinnedModel.items.contains(where: { $0.eventId == eventID && $0.canUnpin }),
              presentedViewController == nil, view.window != nil else { return }
        let alert = UIAlertController(title: String(localized: "Unpin message?", table: "RoomProfile"),
            message: String(localized: "This removes the pin for everyone in the room. The message stays in the chat.", table: "RoomProfile"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Unpin"), style: .destructive) { [weak pinnedModel] _ in
            pinnedModel?.unpin(eventID)
        })
        present(alert, animated: true)
    }

    private func bindProfile() {
        if let personModel { bindPerson(personModel); return }
        guard let profileModel else {
            loadAvatar(AvatarIdentity(id: model?.roomId ?? "", title: titleText, url: room?.avatarUrl()))
            return
        }
        profileModel.$snapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.header.apply(snapshot)
            self.compactTitle.text = snapshot.title
            self.loadAvatar(AvatarIdentity(id: snapshot.directUserID ?? snapshot.roomID,
                title: snapshot.title, url: snapshot.avatarURL))
            self.updateBlocking(userID: snapshot.isDirect ? snapshot.directUserID : nil)
            // @Published delivers before its property changes. Use this value
            // for permissions so a revoked action cannot remain in the menu.
            self.updateProfileMenus(snapshot: snapshot)
            self.view.setNeedsLayout()
        }.store(in: &cancellables)
        profileModel.$notifications.combineLatest(profileModel.$isLoadingNotifications,
            profileModel.$isSavingNotifications, profileModel.$notificationsError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateProfileMenus() }.store(in: &cancellables)
        profileModel.$informationError.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateProfileMenus() }.store(in: &cancellables)
        profileModel.$actionError.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showProfileError() }.store(in: &cancellables)
        profileModel.start()
    }

    private func perform(_ action: RoomProfileAction) {
        if let personModel {
            if action == .message { personModel.openChat() }
            return
        }
        guard profileModel.map({ action.isEnabled(in: $0.snapshot) }) != false else { return }
        switch action {
        case .information: onInformation?()
        case .attachments: onLegacyAttachments?()
        default: onAction?(action)
        }
    }

    private var linkTarget: MatrixLinkTarget? {
        if let personModel { return .person(personModel.snapshot.userID) }
        if let snapshot = profileModel?.snapshot, snapshot.isDirect {
            return snapshot.directUserID.map(MatrixLinkTarget.person)
        }
        // Wait until RoomInfo has identified the room before offering its
        // link; a provisional profile may still turn out to be a DM.
        guard profileModel?.snapshot.notificationContext != nil else { return nil }
        return room.map { .room($0) }
    }

    private func sharingMenu() -> UIMenu {
        ProfileActionMenus.sharing(isPreparing: linkSharing.isPreparing, isAvailable: linkTarget != nil) { [weak self] copy in
            guard let self, let target = self.linkTarget, self.view.window != nil,
                  self.presentedViewController == nil else { return }
            self.linkSharing.prepare(target) { [weak self] url in
                guard let self, self.view.window != nil, self.presentedViewController == nil,
                      self.zynaNavigationController?.topViewController === self else { return }
                if copy {
                    MatrixLinkSharing.copyToPasteboard(url)
                } else {
                    let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    sheet.popoverPresentationController?.sourceView = self.moreButton
                    sheet.popoverPresentationController?.sourceRect = self.moreButton.bounds
                    self.present(sheet, animated: true)
                }
            }
        }
    }

    private func bindSharing() {
        linkSharing.$isPreparing.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            if self.personModel != nil { self.renderPerson() } else { self.updateProfileMenus() }
        }.store(in: &cancellables)
        linkSharing.$error.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] error in
            guard let self, self.view.window != nil, self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: String(localized: "Couldn't create link"),
                                          message: error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            self.present(alert, animated: true)
        }.store(in: &cancellables)
    }

    private func bindPerson(_ person: PersonProfileViewModel) {
        person.$snapshot.combineLatest(person.$isPerformingAction, person.$presence, person.$loadError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderPerson() }.store(in: &cancellables)
        person.$actionError.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showPersonError() }.store(in: &cancellables)
        updateBlocking(userID: person.snapshot.userID)
        person.start()
        renderPerson()
    }

    private func renderPerson() {
        guard let person = personModel else { return }
        let snapshot = person.snapshot
        let presence = person.presence.map { value in
            value.online ? String(localized: "online") : value.lastSeen?.presenceLastSeenString(style: .expanded)
        } ?? nil
        header.apply(snapshot, canOpenChat: person.canOpenChat, presence: presence)
        compactTitle.text = snapshot.title
        loadAvatar(AvatarIdentity(id: snapshot.userID, title: snapshot.title, url: snapshot.avatarURL))
        let menuState = PersonMenuState(snapshot: snapshot,
            performingAction: person.isPerformingAction, hasProfileError: person.loadError != nil,
            isBlocked: person.blocking.isBlocked, savingBlock: person.blocking.isSaving,
            canChangeBlock: person.blocking.canChange, hasBlockError: person.blocking.loadError != nil,
            preparingLink: linkSharing.isPreparing)
        if renderedPersonMenuState != menuState {
            renderedPersonMenuState = menuState
            let menu = ProfileActionMenus.person(person, presenter: self, sharing: sharingMenu())
            moreButton.menu = menu
            header.setMoreMenu(menu)
        }
        if person.isPerformingAction { navigationProgress.startAnimating() }
        else { navigationProgress.stopAnimating() }
        moreButton.isHidden = person.isPerformingAction
        view.setNeedsLayout()
    }

    private func updateBlocking(userID: String?) {
        guard blocking?.userID != userID else { return }
        blocking?.stop()
        blockingObservations.removeAll()
        blocking = personModel?.blocking ?? userID.flatMap(blockingFactory)
        guard let blocking else { return }
        blocking.$isBlocked.combineLatest(blocking.$isSaving, blocking.$loadError)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                if self.personModel != nil { self.renderPerson() }
                else { self.renderedMenuState = nil; self.updateProfileMenus() }
            }.store(in: &blockingObservations)
        blocking.$actionError.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showPersonError() }.store(in: &blockingObservations)
        blocking.start()
    }

    private func showPersonError() {
        guard view.window != nil, presentedViewController == nil,
              let error = personModel?.actionError ?? blocking?.actionError else { return }
        personModel?.actionError = nil
        blocking?.actionError = nil
        let alert = UIAlertController(title: String(localized: "Something went wrong"), message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func updateProfileMenus(snapshot: RoomProfileSnapshot? = nil) {
        guard let profileModel else { return }
        let snapshot = snapshot ?? profileModel.snapshot
        let menuState = MenuState(snapshot: snapshot, notifications: profileModel.notifications,
            loading: profileModel.isLoadingNotifications, saving: profileModel.isSavingNotifications,
            hasNotificationError: profileModel.notificationsError != nil,
            hasInformationError: profileModel.informationError != nil, preparingLink: linkSharing.isPreparing)
        guard renderedMenuState != menuState else { return }
        renderedMenuState = menuState
        let notificationMenu = makeNotificationMenu(snapshot: snapshot)
        var entries: [UIMenuElement] = []
        for action: RoomProfileAction in [.search, .members, .edit, .information, .attachments] {
            if action == .members && snapshot.isDirect { continue }
            if action == .edit && !action.isEnabled(in: snapshot) { continue }
            entries.append(UIAction(title: action.title, image: action.icon.template(size: 18),
                attributes: action.isEnabled(in: snapshot) ? [] : .disabled) { [weak self] _ in self?.perform(action) })
        }
        entries.insert(notificationMenu, at: min(1, entries.count))
        entries.append(sharingMenu())
        if let onReportRoom {
            entries.append(UIAction(title: snapshot.isDirect ? String(localized: "Report conversation", table: "Reports")
                : String(localized: "Report room", table: "Reports"), image: UIImage(systemName: "flag")) { _ in onReportRoom() })
        }
        if let action = ProfileActionMenus.blocking(blocking, presenter: self) { entries.append(action) }
        if profileModel.informationError != nil {
            entries.append(UIAction(title: String(localized: "Reload profile", table: "RoomProfile")) { [weak profileModel] _ in
                profileModel?.reloadInformation()
            })
        }
        let more = UIMenu(children: entries)
        moreButton.menu = more
        let notificationDetail: String
        if profileModel.isSavingNotifications { notificationDetail = String(localized: "Saving", table: "RoomProfile") }
        else if profileModel.notificationsError != nil { notificationDetail = String(localized: "Retry") }
        else if let settings = profileModel.notifications {
            switch settings.mode {
            case .allMessages: notificationDetail = String(localized: "All", table: "RoomProfile")
            case .mentionsAndKeywordsOnly: notificationDetail = String(localized: "Mentions", table: "RoomProfile")
            case .mute: notificationDetail = String(localized: "Muted", table: "RoomProfile")
            }
        } else { notificationDetail = String(localized: "Loading") }
        header.setMenus(more: more, notifications: notificationMenu, notificationDetail: notificationDetail,
            isMuted: profileModel.notifications?.mode == .mute)
    }

    private func makeNotificationMenu(snapshot: RoomProfileSnapshot) -> UIMenu {
        guard let profileModel else { return UIMenu(children: []) }
        let selection = profileModel.notifications.map(RoomNotificationSelection.init)
        var entries: [UIMenuElement] = RoomNotificationSelection.allCases.map { mode in
            let action = UIAction(title: mode.title, attributes: profileModel.canChangeNotifications(for: snapshot) ? [] : .disabled,
                state: selection == mode ? .on : .off) { [weak profileModel] _ in profileModel?.setNotifications(mode) }
            if mode == .inherited, let settings = profileModel.notifications, settings.isDefault {
                let effectiveMode = RoomNotificationSelection(.init(mode: settings.mode, isDefault: false)).title
                action.subtitle = String(localized: "Account default: \(effectiveMode)", table: "RoomProfile")
            }
            return action
        }
        if profileModel.notificationsError != nil {
            entries.append(UIAction(title: String(localized: "Try Again")) { [weak profileModel] _ in
                profileModel?.refreshNotifications()
            })
        }
        return UIMenu(title: RoomProfileAction.notifications.title,
            image: AppIcon.bell.template(size: 18), children: entries)
    }

    private func showProfileError() {
        guard let message = profileModel?.actionError, view.window != nil, presentedViewController == nil else { return }
        profileModel?.actionError = nil
        let alert = UIAlertController(title: String(localized: "Couldn't change notifications", table: "RoomProfile"),
            message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func updatePages(catalogChanged: Bool = false) {
        guard model != nil else { return }
        for (section, page) in pages where section != .pinned {
            let base = catalog[section] ?? []
            let footer = footerRow(isEmpty: section == .media && mediaCatalog.source != nil ? mediaCatalog.count == 0 : base.isEmpty, section: section)
            guard catalogChanged || lastFooter[section] != footer else { continue }
            lastFooter[section] = footer
            projectionQueue.async { [weak page] in
                let rows = base + [footer]
                DispatchQueue.main.async { page?.update(rows) }
            }
        }
    }

    private func footerRow(isEmpty: Bool, section: RoomProfileScrollState.Section) -> RoomProfileRow {
        guard let model else { return .init(id: "footer", title: "", detail: nil, item: nil, isHeader: false, isAction: false) }
        var title = ""
        var detail: String?
        var action = false
        if let error = model.startError { title = String(localized: "Couldn't load attachments."); detail = error }
        else if model.isInitialLoading { title = String(localized: "Loading") }
        else {
            switch model.fillState {
            case .filling, .settling: title = String(localized: "Loading")
            case .failed(let message): title = String(localized: "Try Again"); detail = message; action = true
            case .capped: title = String(localized: "Load More"); action = true
            case .exhausted:
                if isEmpty { title = section == .media ? String(localized: "No photos or videos yet.") : String(localized: "No files yet.") }
            case .idle: if isEmpty { title = String(localized: "Loading") }
            }
        }
        if model.pendingDecryptionCount > 0 {
            detail = String(localized: "\(model.pendingDecryptionCount) messages are waiting for keys")
            if title.isEmpty { title = String(localized: "Retry") }
            action = true
        }
        return RoomProfileRow(id: "footer", title: title, detail: detail, item: nil, isHeader: false, isAction: action)
    }

    @discardableResult
    private func ensurePage(_ section: RoomProfileScrollState.Section) -> any RoomProfileContentPage {
        if let page = pages[section] { return page }
        let page: any RoomProfileContentPage
        if section == .media, personModel == nil {
            let grid = RoomMediaGrid(catalog: mediaCatalog, columns: mediaColumns)
            grid.onColumnsChanged = { [weak self] in self?.mediaColumns = $0 }
            grid.onCountChanged = { [weak self] count in
                guard let self else { return }
                if self.model?.usesPagedMedia == true { self.model?.updatePagedMediaCount(count) }
                self.updatePages()
            }
            page = grid
        } else {
            let list = RoomProfileListPage()
            if section == .pinned {
                list.accessibilityID = "profile.pinned"
                list.onOpenPinned = { [weak self] id in self?.showInChat(id, targetKind: .message) }
                list.onUnpin = { [weak self] id in self?.confirmUnpin(id) }
            }
            page = list
        }
        pages[section] = page
        renderedHeaderGeometry = nil
        lastFooter[section] = nil
        pager.addSubview(page.view)
        page.install()
        page.isActive = section == state.selected
        page.view.accessibilityElementsHidden = section != state.selected
        page.forceLoadIds = model?.forceLoadIds ?? []
        page.fullFileThreshold = model?.fullFileThreshold ?? AttachmentThumbnailPlan.defaultFullFileThreshold
        page.restorationAnchor = anchors.removeValue(forKey: section)
        page.onScroll = { [weak self, weak page] in
            guard let self, let page, self.pages[section] === page,
                  section == self.state.selected, self.state.transition == nil, !self.layingOut else { return }
            self.scrolled(page)
        }
        page.onBeginDragging = { [weak self, weak page] in
            guard let self, let page, self.pages[section] === page,
                  section == self.state.selected, self.state.transition == nil else { return }
            self.stopAvatarAnimation(finish: false)
            if self.state.regularCollapse == 0, self.state.depth(for: section) == 0 {
                self.loadLargeAvatarIfNeeded(retry: true)
            }
            self.avatarDrag = RoomProfileAvatarDrag(progress: self.state.avatarProgress,
                translation: self.avatarDragTranslation(page.scrollView, self.view))
            self.pendingAvatarSnap = nil
            if self.hasAvatarPhoto { self.avatarHaptic.prepare() }
        }
        page.onWillEndDragging = { [weak self, weak page] velocity, offset in
            guard let self, let page, section == self.state.selected else { return }
            self.willEndAvatarDrag(page, velocity: velocity, target: offset)
        }
        page.onEndDragging = { [weak self, weak page] in
            guard let self, let page, section == self.state.selected else { return }
            // A cancelled pan can end without willEndDragging, and UIKit's
            // callback may run before our pan target receives .cancelled.
            let drag = self.avatarDrag
            self.avatarDrag = nil
            let cancelledTarget = drag.flatMap { drag -> CGFloat? in
                guard self.state.collapse < self.state.avatarExpansionHeight else { return nil }
                return drag.initiallyExpanded ? 0 : self.state.avatarExpansionHeight
            }
            guard let target = self.pendingAvatarSnap ?? cancelledTarget else { return }
            self.pendingAvatarSnap = target
            // UIScrollView finishes its own drag bookkeeping first.
            let generation = self.avatarAnimationGeneration
            DispatchQueue.main.async { [weak self, weak page] in
                guard let self, let page, generation == self.avatarAnimationGeneration,
                      self.state.transition == nil, self.avatarDrag == nil, page.isActive else { return }
                self.animateAvatar(to: target)
            }
        }
        page.scrollView.panGestureRecognizer.addTarget(self, action: #selector(pagePanCancelled(_:)))
        page.onSelect = { [weak self] item, preview, frame in self?.open(item, preview: preview, from: frame) }
        page.onShowInChat = { [weak self] item in self?.showInChat(item.id) }
        page.onContextInteractionChanged = { [weak self] locked in
            guard let self else { return }
            self.pager.isScrollEnabled = !locked && self.personModel == nil
            self.tabs.isEnabled = !locked
            self.topButton.isEnabled = !locked
            if !locked { self.updatePinnedSection() }
        }
        page.onRequestImage = { [weak self] item in self?.model?.requestLoad(item) }
        page.onLoad = { [weak self] in
            if section == .pinned { self?.pinnedModel?.reload(); return }
            guard let model = self?.model else { return }
            if model.pendingDecryptionCount > 0 { model.retryDecryption(reason: "profile") }
            model.loadMoreTapped()
        }
        page.onAnchorRestored = { [weak self, weak page] depth in
            guard let self, let page, self.pages[section] === page else { return }
            self.state.restoreDepth(depth, for: section)
        }
        page.onNearEnd = { [weak self] near in
            guard section != .pinned else { return }
            let tab: RoomAttachmentsViewModel.Tab = section == .media ? .media : .files
            if near { self?.model?.sentinelAppeared(in: tab, from: .profile) }
            else { self?.model?.sentinelDisappeared(in: tab, from: .profile) }
        }
        if section == state.selected { updateSharedPan() }
        if section == .pinned { updatePinnedPage() } else { updatePages() }
        view.setNeedsLayout()
        return page
    }

    /// Keep UIKit's pan, inertia and delegate callbacks, while letting a drag
    /// start on the sibling header's controls. Only the selected page owns the
    /// shared surface; the navigation bar and player remain outside it.
    private func updateSharedPan() {
        guard let scrollView = pages[state.selected]?.scrollView else { return }
        if sharedPanScrollView !== scrollView {
            if let previous = sharedPanScrollView {
                previous.addGestureRecognizer(previous.panGestureRecognizer)
            }
            contentNode.view.addGestureRecognizer(scrollView.panGestureRecognizer)
            sharedPanScrollView = scrollView
        }
        scrollView.panGestureRecognizer.isEnabled = state.transition == nil && scrollView.isScrollEnabled
    }

    private func renderHeader() {
        let top = pager.frame.minY
        let geometry = HeaderGeometry(top: top, width: view.bounds.width,
            height: state.headerHeight, collapse: state.collapse, expansion: state.avatarExpansionHeight)
        let geometryChanged = renderedHeaderGeometry != geometry
        let hideTopButton = state.depth(for: state.selected) < 100 || state.transition != nil
        if topButton.isHidden != hideTopButton { topButton.isHidden = hideTopButton }
        if geometryChanged {
            renderedHeaderGeometry = geometry
            header.frame = CGRect(x: 0, y: top + state.avatarExpansionHeight - state.collapse,
                width: view.bounds.width, height: state.headerHeight - state.avatarExpansionHeight)
            avatarView.update(width: view.bounds.width, top: top, progress: state.avatarProgress,
                collapse: state.regularCollapse, canExpand: hasAvatarPhoto)
            tabBackground.frame = CGRect(x: 0, y: top + state.headerHeight - state.collapse, width: view.bounds.width, height: tabHeight)
            tabs.frame = tabBackground.bounds.insetBy(dx: 16, dy: 7)
            let alpha = state.regularCollapseProgress
            compactTitle.alpha = alpha
            compactAvatar.alpha = alpha
            if profileModel != nil || personModel != nil {
                moreButton.alpha = alpha
                moreButton.accessibilityElementsHidden = alpha < 0.95
            }
            header.accessibilityElementsHidden = alpha > 0.95
            compactTitle.accessibilityElementsHidden = alpha < 0.95
        }
        // Deep vertical scrolling changes only the selected page's depth.
        // Leave the compact header and inactive collections untouched.
        guard geometryChanged || state.transition != nil else { return }
        for (section, page) in pages {
            page.collapse = state.collapse
            if section != state.selected || state.transition != nil {
                page.setPosition(depth: state.depth(for: section))
            } else {
                page.scrollView.verticalScrollIndicatorInsets.top = page.inset - state.collapse
            }
        }
    }

    private func scrolled(_ page: any RoomProfileContentPage) {
        let wasCircular = state.avatarProgress == 0
        var offset = page.normalizedOffset
        if state.avatarExpansionHeight > 0,
           let delta = avatarDrag?.scrollDelta(translation: avatarDragTranslation(page.scrollView, view)) {
            state.scroll(to: state.collapse + state.depth(for: state.selected) + delta,
                avatarScrollSpeed: RoomProfileAvatarDrag.scrollSpeed)
            offset = state.collapse + state.depth(for: state.selected)
        } else {
            // Momentum or a layout correction may reveal the ordinary header,
            // but only a finger (or the explicit tap animation) opens the photo.
            if state.avatarExpansionHeight > 0, avatarDrag == nil, avatarAnimation == nil, wasCircular {
                offset = max(state.avatarExpansionHeight, offset)
            }
            if state.avatarExpansionHeight > 0 { offset = max(0, offset) }
            state.scroll(to: offset)
        }
        if offset != page.normalizedOffset {
            page.collapse = state.collapse
            page.setPosition(depth: state.depth(for: state.selected))
            // Keep the next physical delta relative to UIKit's origin after
            // the correction, including any native pan rebasing.
            avatarDrag?.rebaseTranslation(avatarDragTranslation(page.scrollView, view))
        }
        if avatarDrag?.update(collapse: state.collapse, expansion: state.avatarExpansionHeight) == true {
            avatarHaptic.impactOccurred()
        }
        renderHeader()
    }

    private func willEndAvatarDrag(_ page: any RoomProfileContentPage, velocity: CGPoint,
                                   target: UnsafeMutablePointer<CGPoint>) {
        let expansion = state.avatarExpansionHeight
        guard expansion > 0 else { return }
        if state.collapse < expansion {
            if avatarDrag?.finish(velocity: velocity.y) == true { avatarHaptic.impactOccurred() }
            pendingAvatarSnap = (avatarDrag?.wantsExpanded ?? (state.avatarProgress >= 0.5)) ? 0 : expansion
            target.pointee = page.scrollView.contentOffset
        } else {
            target.pointee.y = max(target.pointee.y, expansion - page.inset)
        }
    }

    @objc private func pagePanCancelled(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .cancelled || pan.state == .failed else { return }
        guard let drag = avatarDrag, state.transition == nil else { return }
        avatarDrag = nil
        pendingAvatarSnap = nil
        if state.collapse < state.avatarExpansionHeight {
            animateAvatar(to: drag.initiallyExpanded ? 0 : state.avatarExpansionHeight)
        }
    }

    private func settleInterruptedAvatar() {
        if let target = pendingAvatarSnap {
            setAvatarCollapse(target)
        } else if let drag = avatarDrag, state.collapse < state.avatarExpansionHeight {
            setAvatarCollapse(drag.initiallyExpanded ? 0 : state.avatarExpansionHeight)
        }
        avatarDrag = nil
        pendingAvatarSnap = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === avatarTap else { return true }
        let point = touch.location(in: view)
        return hasAvatarPhoto && state.transition == nil && point.y >= pager.frame.minY
            && avatarView.frame.contains(point)
    }

    @objc private func toggleAvatar() {
        guard hasAvatarPhoto, state.transition == nil, personModel != nil || pager.isScrollEnabled else { return }
        if state.avatarProgress < 0.5 { loadLargeAvatarIfNeeded(retry: true) }
        avatarHaptic.impactOccurred()
        animateAvatar(to: state.avatarProgress >= 0.5 ? state.avatarExpansionHeight : 0)
    }

    private func setAvatarCollapse(_ value: CGFloat) {
        state.setHeaderCollapse(value)
        if let page = pages[state.selected] {
            page.collapse = state.collapse
            page.setPosition(depth: state.depth(for: state.selected))
        }
        renderHeader()
    }

    private func stopAvatarAnimation(finish: Bool) {
        avatarAnimationGeneration += 1
        avatarAnimation?.invalidate()
        avatarAnimation = nil
        let target = avatarAnimationTarget
        avatarAnimationTarget = nil
        if finish, let target { setAvatarCollapse(target) }
    }

    private func animateAvatar(to target: CGFloat) {
        stopAvatarAnimation(finish: false)
        pendingAvatarSnap = nil
        guard state.transition == nil, let page = pages[state.selected] else { return }
        // Stop native deceleration and its booster before the shared clock
        // takes over; an interrupted scroll need not send didEndDecelerating.
        page.stopScrolling()
        let start = state.collapse
        guard !UIAccessibility.isReduceMotionEnabled, abs(start - target) > 0.5 else {
            setAvatarCollapse(target)
            return
        }
        avatarAnimationTarget = target
        let began = CACurrentMediaTime()
        let duration = IOS26Spring.duration
        avatarAnimation = DisplayLinkDriver.shared.subscribe(rate: .max) { [weak self] frame in
            guard let self else { return }
            let elapsed = max(0, frame.targetTimestamp - began)
            // The app's spring is almost critically damped. Normalize its
            // response so both geometry and scroll stop at the same endpoint.
            let omega = 23.559
            func response(_ time: Double) -> Double { 1 - (1 + omega * time) * exp(-omega * time) }
            let progress = min(1, response(min(duration, elapsed)) / response(duration))
            self.setAvatarCollapse(start + (target - start) * progress)
            if elapsed >= duration { self.stopAvatarAnimation(finish: true) }
        }
    }

    @objc private func goBack() { onBack?() }

    @objc private func selectTab() {
        guard sections.indices.contains(tabs.selectedSegmentIndex) else { return }
        selectSection(sections[tabs.selectedSegmentIndex], animated: true)
    }

    func selectSection(_ target: RoomProfileScrollState.Section, animated: Bool) {
        loadViewIfNeeded()
        // Stop the previous programmatic journey before starting a new one.
        // Otherwise its later animation callback could commit the wrong page.
        if state.transition != nil {
            let width = pager.bounds.width
            let index = width > 0 ? (pager.contentOffset.x / width).rounded() : 0
            pager.setContentOffset(CGPoint(x: index * width, y: 0), animated: false)
            finishPaging()
        }
        if target == .pinned { keepsPinnedSection = true; updatePinnedSection() }
        guard let index = sections.firstIndex(of: target), target != state.selected else { return }
        beginPaging()
        ensurePage(target)
        view.layoutIfNeeded()
        if !animated || UIAccessibility.isReduceMotionEnabled {
            pager.setContentOffset(CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0), animated: false)
            finishPaging()
        } else {
            pager.setContentOffset(CGPoint(x: CGFloat(index) * pager.bounds.width, y: 0), animated: true)
        }
    }

    @objc private func scrollToBeginning() {
        guard state.transition == nil else { return }
        pages[state.selected]?.scrollToBeginning(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func beginPaging() {
        guard personModel == nil else { return }
        settleInterruptedAvatar()
        pagingAvatarTarget = avatarAnimationTarget
        stopAvatarAnimation(finish: false)
        sharedPanScrollView?.panGestureRecognizer.isEnabled = false
        pages[state.selected]?.isActive = false
        fpsBooster.start()
        state.beginTransition()
        if let index = sections.firstIndex(of: state.selected) {
            for neighbor in max(0, index - 1)...min(sections.count - 1, index + 1) {
                ensurePage(sections[neighbor])
            }
        }
        view.layoutIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { beginPaging() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !layingOut, state.transition != nil, pager.bounds.width > 0 else { return }
        let position = pager.contentOffset.x / pager.bounds.width
        // A tab tap can travel across several pages. Materialize only the
        // pair currently crossing the viewport, also when the gesture reverses.
        let clamped = min(CGFloat(sections.count - 1), max(0, position))
        var addedPage = false
        for index in Int(clamped.rounded(.down))...Int(clamped.rounded(.up)) where pages[sections[index]] == nil {
            ensurePage(sections[index]); addedPage = true
        }
        if addedPage { view.layoutIfNeeded() }
        state.transition(at: position, sections: sections)
        renderHeader()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishPaging() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishPaging() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { finishPaging() }

    private func finishPaging() {
        fpsBooster.stop()
        guard pager.bounds.width > 0 else { return }
        let index = min(sections.count - 1, max(0, Int((pager.contentOffset.x / pager.bounds.width).rounded())))
        let section = sections[index]
        state.finishTransition(at: section)
        if section == .pinned { keepsPinnedSection = true }
        updateSharedPan()
        tabs.selectedSegmentIndex = index
        if section != .pinned { model?.tab = section == .media ? .media : .files }
        startAttachmentsIfNeeded()
        for (key, page) in pages {
            page.isActive = key == section
            page.view.accessibilityElementsHidden = key != section
            page.collapse = state.collapse
            page.setPosition(depth: state.depth(for: key))
            page.updateNearEnd()
        }
        renderHeader()
        updatePinnedSection()
        let target = pagingAvatarTarget
        pagingAvatarTarget = nil
        if state.avatarProgress > 0, state.avatarProgress < 1 {
            animateAvatar(to: target ?? (state.avatarProgress >= 0.5 ? 0 : state.avatarExpansionHeight))
        }
    }

    private func open(_ item: AttachmentItem, preview: UIImage?, from frame: CGRect) {
        guard let model else { return }
        if item.kind == .image {
            if let source = mediaCatalog.source, let onOpenMediaImage {
                imageTask?.cancel()
                imageTask = Task { [weak self] in
                    do { try await onOpenMediaImage(source, item, frame) }
                    catch is CancellationError {}
                    catch { self?.model?.downloadError = error.localizedDescription }
                }
                return
            }
            let groups = model.media
            let tileSize = model.tilePixelSize
            imageTask?.cancel()
            imageTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    let images = groups.flatMap(\.items).filter { $0.kind == .image }
                    let index = images.firstIndex { $0.id == item.id }
                    let items = images.map {
                        ImageViewerController.Item(previewImage: MediaCache.shared.cachedAttachmentThumbnail(
                            mxc: $0.thumbnail?.mxc ?? $0.sourceMxc, tilePixelSize: tileSize),
                            mediaSource: $0.source, sourceFrame: $0.id == item.id ? frame : .zero)
                    }
                    return (items, index)
                }.value
                guard !Task.isCancelled, let index = result.1 else { return }
                self?.actions.openImages(result.0, index)
            }
        } else {
            guard model.beginDownload(item.id) else { return }
            let callback: (AttachmentDownloadEvent) -> Void = { [weak model] event in
                Task { @MainActor in model?.handleDownloadEvent(event, for: item.id) }
            }
            if item.kind == .video { actions.openVideo(item, preview ?? model.previewImage(for: item), frame, callback) }
            else { actions.openFile(item, callback) }
        }
    }

    private func showInChat(_ eventId: String, targetKind: ChatCatalogTarget = .attachment) {
        guard navigationTask == nil, let operation = onShowInChat else { return }
        moreButton.isHidden = true
        navigationProgress.startAnimating()
        navigationTask = Task { [weak self] in
            defer {
                self?.navigationTask = nil
                self?.moreButton.isHidden = false
                self?.navigationProgress.stopAnimating()
            }
            do {
                let prepared = try await operation(eventId, targetKind)
                try Task.checkCancellation()
                guard prepared.open() else { throw PollNavigationError.unavailable }
            } catch is CancellationError {
            } catch {
                guard let self, self.view.window != nil, self.presentedViewController == nil else { return }
                let alert = UIAlertController(title: String(localized: "Couldn't open message", table: "RoomProfile"),
                    message: String(localized: "The message may have been deleted or its history is unavailable. Try again.", table: "RoomProfile"),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func showDownloadError() {
        guard let error = model?.downloadError, !isPresentingError, presentedViewController == nil, view.window != nil else { return }
        isPresentingError = true
        let alert = UIAlertController(title: String(localized: "Download failed"), message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.model?.downloadError = nil; self?.isPresentingError = false
        })
        present(alert, animated: true)
    }

    private func loadAvatar(_ identity: AvatarIdentity) {
        guard avatarIdentity != identity else { return }
        let keepsPhoto = hasAvatarPhoto && avatarIdentity?.url == identity.url
        avatarIdentity = identity
        if keepsPhoto { return }
        avatarTask?.cancel(); largeAvatarTask?.cancel()
        requestedAvatarPixels = 0
        loadedAvatarPixels = 0
        largeAvatarTask = nil
        hasAvatarPhoto = false
        avatarView.image = nil
        compactAvatar.image = nil
        renderedHeaderGeometry = nil
        view.setNeedsLayout()
        let loader = avatarLoader
        let avatar = AvatarViewModel(userId: identity.id, displayName: identity.title, mxcAvatarURL: identity.url)
        avatarTask = Task { [weak self] in
            let placeholder = await Task.detached(priority: .userInitiated) { avatar.circleImage(diameter: 88, fontSize: 32) }.value
            guard !Task.isCancelled else { return }
            self?.avatarView.image = placeholder
            self?.compactAvatar.image = placeholder
            if let mxc = identity.url, let image = await loader(mxc, 240) {
                guard !Task.isCancelled, let self else { return }
                self.avatarView.image = image
                self.compactAvatar.image = image
                self.hasAvatarPhoto = true
                self.renderedHeaderGeometry = nil
                self.view.setNeedsLayout()
                self.loadLargeAvatarIfNeeded()
            }
        }
    }

    private func loadLargeAvatarIfNeeded(retry: Bool = false) {
        guard hasAvatarPhoto, let mxc = avatarIdentity?.url, view.bounds.width > 0 else { return }
        let pixels = min(1536, Int(ceil(view.bounds.width * view.traitCollection.displayScale)))
        guard pixels > loadedAvatarPixels,
              pixels > requestedAvatarPixels || (retry && largeAvatarTask == nil) else { return }
        requestedAvatarPixels = pixels
        largeAvatarTask?.cancel()
        let loader = avatarLoader
        largeAvatarTask = Task { [weak self] in
            let image = await loader(mxc, pixels)
            guard !Task.isCancelled, let self else { return }
            self.largeAvatarTask = nil
            if let image {
                self.loadedAvatarPixels = pixels
                self.avatarView.image = image
            }
        }
    }

}

final class RoomProfilePagerScrollView: UIScrollView, InteractiveBackScrollPolicy {
    var canStartBackFromAnywhere: (() -> Bool)?

    func allowsInteractiveBack(at point: CGPoint) -> Bool {
        guard isScrollEnabled else { return false }
        return canStartBackFromAnywhere?() == true || point.x - bounds.minX < 24
    }

    func yieldsPanToInteractiveBack(from point: CGPoint, velocity: CGPoint) -> Bool {
        velocity.x > abs(velocity.y) && allowsInteractiveBack(at: point)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            let location = panGestureRecognizer.location(in: self)
            let translation = panGestureRecognizer.translation(in: self)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            // Match the navigation recognizer's touch-start policy so the
            // pager cannot claim a right swipe that belongs to back.
            if yieldsPanToInteractiveBack(from: start, velocity: velocity) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
