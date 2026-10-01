// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import Combine
import MatrixRustSDK

/// First Texture profile slice. Other profile actions still route to the
/// existing room information screen until their planned migration.
final class RoomProfileViewController: ASDKViewController<ASDisplayNode>, UIScrollViewDelegate {
    var onBack: (() -> Void)?
    var onInformation: (() -> Void)?
    var onLegacyAttachments: (() -> Void)?
    var onShowInChat: ((String) async throws -> PreparedPollNavigation)?
    var onOpenMediaImage: ((RoomMediaDatabase, AttachmentItem, CGRect) async throws -> Void)?

    private let model: RoomAttachmentsViewModel
    private let actions: RoomAttachmentsActions
    private let room: Room?
    private let titleText: String
    private let header: RoomProfileHeaderNode
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
    private var navigationTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var playerHost: EmbeddedVoiceTopPlayerHost?
    private var attached = false
    private var layingOut = false
    private var previousWidth: CGFloat = 0
    private var isPresentingError = false
    private let tabHeight: CGFloat = 48
    private struct HeaderGeometry: Equatable {
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
        let collapse: CGFloat
    }
    private var renderedHeaderGeometry: HeaderGeometry?

    init(room: Room?, title: String, subtitle: String, model: RoomAttachmentsViewModel,
         actions: RoomAttachmentsActions, audioPlayer: AudioPlayerService? = nil, mediaCatalog: RoomMediaCatalog? = nil) {
        self.room = room
        self.titleText = title
        self.model = model
        self.actions = actions
        self.mediaCatalog = mediaCatalog ?? RoomMediaCatalog()
        header = RoomProfileHeaderNode(title: title, subtitle: subtitle)
        super.init(node: ASDisplayNode())
        node.backgroundColor = .appBG
        hidesBottomBarWhenPushed = true
        if let audioPlayer { playerHost = EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: audioPlayer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { startTask?.cancel(); avatarTask?.cancel(); navigationTask?.cancel(); imageTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(pager)
        node.addSubnode(header)
        header.isUserInteractionEnabled = false
        view.addSubview(tabBackground)
        tabBackground.addSubview(tabs)
        view.addSubview(bar)
        [compactAvatar, compactTitle, backButton, moreButton, navigationProgress].forEach { bar.addSubview($0) }
        view.addSubview(topButton)
        bar.backgroundColor = .appBG
        tabBackground.backgroundColor = .appBG
        pager.delegate = self
        pager.canStartBackFromAnywhere = { [weak self] in
            guard let self else { return false }
            return self.state.selected == .media && self.state.transition == nil
        }
        pager.isPagingEnabled = true
        pager.isDirectionalLockEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.bounces = false
        pager.scrollsToTop = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.accessibilityIdentifier = "profile.pager"
        tabs.selectedSegmentIndex = 0
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
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
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
        ensurePage(.media)
        bind()
        loadAvatar()
        startTask = Task { [weak self] in await self?.model.start() }
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
            model.stop()
            mediaCatalog.stop()
            cancellables.removeAll()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pages[state.selected]?.isActive = true
        playerHost?.refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pages.values.forEach { $0.dismissContextMenu(); $0.isActive = false }
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
        let top = view.safeAreaInsets.top + 48
        let measured = header.layoutThatFits(ASSizeRange(min: CGSize(width: width, height: 0),
            max: CGSize(width: width, height: .greatestFiniteMagnitude))).size.height
        let height = max(208, measured)
        if state.headerHeight != height { state.resizeHeader(to: height) }
        if width != previousWidth, state.transition != nil {
            fpsBooster.stop()
            state.finishTransition(at: state.selected)
            for (section, page) in pages { page.isActive = section == state.selected }
        }
        pager.frame = CGRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top))
        pager.contentSize = CGSize(width: width * 2, height: pager.bounds.height)
        if width != previousWidth { pager.contentOffset.x = width * CGFloat(state.selected.rawValue); previousWidth = width }
        bar.frame = CGRect(x: 0, y: 0, width: width, height: top)
        backButton.frame = CGRect(x: 8, y: top - 48, width: 44, height: 44)
        moreButton.frame = CGRect(x: width - 52, y: top - 48, width: 44, height: 44)
        navigationProgress.frame = moreButton.frame
        compactAvatar.frame = CGRect(x: 58, y: top - 42, width: 32, height: 32)
        compactTitle.frame = CGRect(x: 100, y: top - 48, width: max(0, width - 158), height: 44)
        topButton.frame = CGRect(x: width - 64, y: view.bounds.height - view.safeAreaInsets.bottom - 64, width: 48, height: 48)
        for (section, page) in pages {
            page.headerHeight = state.headerHeight
            page.tabsHeight = tabHeight
            page.collapse = state.collapse
            page.layout(frame: CGRect(x: width * CGFloat(section.rawValue), y: 0, width: width, height: pager.bounds.height),
                        depth: state.depth(for: section), bottomInset: view.safeAreaInsets.bottom)
        }
        renderHeader()
        playerHost?.layout()
    }

    private func bind() {
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

    private func updatePages(catalogChanged: Bool = false) {
        for (section, page) in pages {
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
        if section == .media {
            let grid = RoomMediaGrid(catalog: mediaCatalog, columns: mediaColumns)
            grid.onColumnsChanged = { [weak self] in self?.mediaColumns = $0 }
            grid.onCountChanged = { [weak self] count in
                guard let self else { return }
                if self.model.usesPagedMedia { self.model.updatePagedMediaCount(count) }
                self.updatePages()
            }
            page = grid
        } else {
            page = RoomProfileFilePage()
        }
        pages[section] = page
        renderedHeaderGeometry = nil
        lastFooter[section] = nil
        pager.addSubview(page.view)
        page.install()
        page.isActive = section == state.selected
        page.forceLoadIds = model.forceLoadIds
        page.fullFileThreshold = model.fullFileThreshold
        page.restorationAnchor = anchors.removeValue(forKey: section)
        page.onScroll = { [weak self, weak page] in
            guard let self, let page, self.pages[section] === page,
                  section == self.state.selected, self.state.transition == nil, !self.layingOut else { return }
            self.state.scroll(to: page.normalizedOffset)
            self.renderHeader()
        }
        page.onSelect = { [weak self] item, preview, frame in self?.open(item, preview: preview, from: frame) }
        page.onShowInChat = { [weak self] item in self?.showInChat(item.id) }
        page.onContextInteractionChanged = { [weak self] locked in
            self?.pager.isScrollEnabled = !locked
            self?.tabs.isEnabled = !locked
            self?.topButton.isEnabled = !locked
        }
        page.onRequestImage = { [weak self] item in self?.model.requestLoad(item) }
        page.onLoad = { [weak self] in
            guard let self else { return }
            if self.model.pendingDecryptionCount > 0 { self.model.retryDecryption(reason: "profile") }
            self.model.loadMoreTapped()
        }
        page.onAnchorRestored = { [weak self, weak page] depth in
            guard let self, let page, self.pages[section] === page else { return }
            self.state.restoreDepth(depth, for: section)
        }
        page.onNearEnd = { [weak self] near in
            let tab: RoomAttachmentsViewModel.Tab = section == .media ? .media : .files
            if near { self?.model.sentinelAppeared(in: tab, from: .profile) }
            else { self?.model.sentinelDisappeared(in: tab, from: .profile) }
        }
        updatePages()
        view.setNeedsLayout()
        return page
    }

    private func renderHeader() {
        let top = pager.frame.minY
        let geometry = HeaderGeometry(top: top, width: view.bounds.width,
            height: state.headerHeight, collapse: state.collapse)
        let geometryChanged = renderedHeaderGeometry != geometry
        let hideTopButton = state.depth(for: state.selected) < 100 || state.transition != nil
        if topButton.isHidden != hideTopButton { topButton.isHidden = hideTopButton }
        if geometryChanged {
            renderedHeaderGeometry = geometry
            header.frame = CGRect(x: 0, y: top - state.collapse, width: view.bounds.width, height: state.headerHeight)
            tabBackground.frame = CGRect(x: 0, y: top + state.headerHeight - state.collapse, width: view.bounds.width, height: tabHeight)
            tabs.frame = tabBackground.bounds.insetBy(dx: 16, dy: 7)
            let alpha = state.collapse / state.headerHeight
            compactTitle.alpha = alpha
            compactAvatar.alpha = alpha
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

    @objc private func goBack() { onBack?() }

    @objc private func selectTab() {
        guard let target = RoomProfileScrollState.Section(rawValue: tabs.selectedSegmentIndex), target != state.selected else { return }
        beginPaging()
        if UIAccessibility.isReduceMotionEnabled {
            pager.setContentOffset(CGPoint(x: CGFloat(target.rawValue) * pager.bounds.width, y: 0), animated: false)
            finishPaging()
        } else {
            pager.setContentOffset(CGPoint(x: CGFloat(target.rawValue) * pager.bounds.width, y: 0), animated: true)
        }
    }

    @objc private func scrollToBeginning() {
        guard state.transition == nil else { return }
        pages[state.selected]?.scrollToBeginning(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func beginPaging() {
        pages[state.selected]?.isActive = false
        fpsBooster.start()
        state.beginTransition()
        for section in RoomProfileScrollState.Section.allCases { ensurePage(section) }
        view.layoutIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { beginPaging() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !layingOut, let transition = state.transition, pager.bounds.width > 0 else { return }
        let position = pager.contentOffset.x / pager.bounds.width
        let target: RoomProfileScrollState.Section = transition.source == .media ? .files : .media
        state.transition(to: target, progress: abs(position - CGFloat(transition.source.rawValue)))
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
        let index = min(1, max(0, Int((pager.contentOffset.x / pager.bounds.width).rounded())))
        guard let section = RoomProfileScrollState.Section(rawValue: index) else { return }
        state.finishTransition(at: section)
        tabs.selectedSegmentIndex = index
        model.tab = section == .media ? .media : .files
        for (key, page) in pages {
            page.isActive = key == section
            page.view.accessibilityElementsHidden = key != section
            page.collapse = state.collapse
            page.setPosition(depth: state.depth(for: key))
            page.updateNearEnd()
        }
        renderHeader()
    }

    private func open(_ item: AttachmentItem, preview: UIImage?, from frame: CGRect) {
        if item.kind == .image {
            if let source = mediaCatalog.source, let onOpenMediaImage {
                imageTask?.cancel()
                imageTask = Task { [weak self] in
                    do { try await onOpenMediaImage(source, item, frame) }
                    catch is CancellationError {}
                    catch { self?.model.downloadError = error.localizedDescription }
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

    private func showInChat(_ eventId: String) {
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
                let prepared = try await operation(eventId)
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
        guard let error = model.downloadError, !isPresentingError, presentedViewController == nil, view.window != nil else { return }
        isPresentingError = true
        let alert = UIAlertController(title: String(localized: "Download failed"), message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.model.downloadError = nil; self?.isPresentingError = false
        })
        present(alert, animated: true)
    }

    private func loadAvatar() {
        let avatar = AvatarViewModel(userId: model.roomId, displayName: titleText, mxcAvatarURL: room?.avatarUrl())
        avatarTask = Task { [weak self] in
            let placeholder = await Task.detached(priority: .userInitiated) { avatar.circleImage(diameter: 88, fontSize: 32) }.value
            guard !Task.isCancelled else { return }
            self?.header.avatar.image = placeholder
            self?.compactAvatar.image = placeholder
            if let mxc = avatar.mxcAvatarURL, let image = await MediaCache.shared.loadThumbnail(mxcUrl: mxc, size: 240) {
                guard !Task.isCancelled else { return }
                self?.header.avatar.image = image
                self?.compactAvatar.image = image
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
