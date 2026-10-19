// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit
import Combine

enum RoomProfilePollAction: Equatable {
    case open(String), cancelOpening(String), loadMore, retryDecryption
}

/// Only display strings cross into Texture; poll results stay in the catalog.
struct RoomProfilePollRow: Equatable {
    let eventID: String
    let question: String
    let author: String
    let date: String
    let summary: String
    let isOpening: Bool
    let failedOpening: Bool
}

struct RoomProfilePollSnapshot: Equatable {
    let items: [RoomPollItem]
    let state: RoomPollsViewModel.State
    let pendingKeys: Int
    let hasLoadedCache: Bool
    let isRefreshing: Bool
    let openingID: String?
    let failedOpeningID: String?

    @MainActor init(model: RoomPollsViewModel) {
        items = model.items
        state = model.state
        pendingKeys = model.pendingDecryptionCount
        hasLoadedCache = model.hasLoadedCache
        isRefreshing = model.isRefreshing
        openingID = model.openingEventId
        failedOpeningID = model.failedOpeningEventId
    }

    func rows() -> [RoomProfileRow] {
        var rows = items.map { item in
            let opening = openingID == item.eventId, failed = failedOpeningID == item.eventId
            let summary: String
            if opening {
                summary = String(localized: "Opening poll… Tap to cancel.", table: "RoomProfile")
            } else if failed {
                summary = String(localized: "Couldn't open poll. Tap to try again.", table: "RoomProfile")
            } else {
                let status = item.snapshot.hasEnded ? String(localized: "Poll ended") : String(localized: "Poll active")
                let results = item.snapshot.showsResults ? String(localized: "\(item.snapshot.totalVoters) voters")
                    : String(localized: "Results after the poll ends")
                summary = [status, results].joined(separator: " · ")
            }
            let poll = RoomProfilePollRow(eventID: item.eventId, question: item.snapshot.definition.question,
                author: item.senderName ?? item.senderId,
                date: Date(timeIntervalSince1970: item.timestamp).formatted(date: .abbreviated, time: .omitted),
                summary: summary, isOpening: opening, failedOpening: failed)
            return RoomProfileRow(id: item.eventId, title: poll.question, detail: summary,
                item: nil, isHeader: false, isAction: true, poll: poll)
        }
        if pendingKeys > 0 {
            rows.append(RoomProfileRow(id: "polls.keys", title: String(localized: "Retry"),
                detail: String(localized: "\(pendingKeys) messages are waiting for keys"),
                item: nil, isHeader: false, isAction: true, pollAction: .retryDecryption))
        }
        let title: String
        var detail: String?
        var action: RoomProfilePollAction?
        switch state {
        case .idle: title = hasLoadedCache && items.isEmpty ? String(localized: "Loading") : ""
        case .loading:
            title = !isRefreshing || (hasLoadedCache && items.isEmpty) ? String(localized: "Loading") : ""
        case .more: title = String(localized: "Load More"); action = .loadMore
        case .failed:
            title = String(localized: "Try Again")
            detail = String(localized: "Couldn't load polls.")
            action = .loadMore
        case .exhausted: title = items.isEmpty && pendingKeys == 0 ? String(localized: "No polls yet.") : ""
        }
        if !title.isEmpty {
            rows.append(RoomProfileRow(id: "polls.status", title: title, detail: detail, item: nil,
                isHeader: false, isAction: action != nil, pollAction: action))
        }
        return rows
    }
}

/// Formatting is lazy and off-main. Hidden/evicted pages do not project
/// catalog updates; reopening starts with the latest model snapshot.
@MainActor
final class RoomProfilePollsSection {
    let model: RoomPollsViewModel
    var openPoll: ((String) async throws -> PreparedPollNavigation)?
    private weak var page: RoomProfileListPage?
    private let queue = DispatchQueue(label: "zyna.profile.polls", qos: .userInitiated)
    private var observation: AnyCancellable?
    private var cacheTask: Task<Void, Never>?
    private var revision = 0
    private var isNearEnd = false
    var isPaging = false {
        didSet { model.setNavigationSuspended(isPaging) }
    }
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                model.activate()
                if isNearEnd { model.reachedBottom() } else { model.leftBottom() }
            }
            else { model.deactivate(); model.leftBottom() }
            connect()
        }
    }

    init(model: RoomPollsViewModel) {
        self.model = model
        cacheTask = Task { [weak self, model] in
            await model.prepareCached()
            guard !Task.isCancelled, let self, !self.isActive else { return }
            self.connect()
        }
    }

    deinit { cacheTask?.cancel() }

    func attach(to page: RoomProfileListPage) {
        self.page = page
        isNearEnd = false
        model.leftBottom()
        page.onPollAction = { [weak self] action in self?.perform(action) }
        page.onNearEnd = { [weak self, weak page] near in
            guard let self, let page, self.page === page else { return }
            // Page activation can report its geometry before the section
            // becomes active. Keep that value instead of dropping the edge.
            self.isNearEnd = near
            guard self.isActive else { return }
            if near { self.model.reachedBottom() } else { self.model.leftBottom() }
        }
        connect()
    }

    func stop() {
        cacheTask?.cancel()
        cacheTask = nil
        observation = nil
        revision += 1
        model.stop()
    }

    private func connect() {
        observation = nil
        revision += 1
        guard let page else { return }
        let revision = revision
        let snapshot = RoomProfilePollSnapshot(model: model)
        let updates: AnyPublisher<RoomProfilePollSnapshot, Never>
        if isActive {
            // Read after @Published commits its values. Coalesce downstream
            // without postponing cached content behind a stream of SDK diffs.
            updates = model.objectWillChange.receive(on: DispatchQueue.main)
                .map { [model] in RoomProfilePollSnapshot(model: model) }
                .prepend(snapshot).eraseToAnyPublisher()
        } else {
            updates = Just(snapshot).eraseToAnyPublisher()
        }
        observation = updates.receive(on: queue).removeDuplicates()
            .throttle(for: .milliseconds(20), scheduler: queue, latest: true)
            .map { $0.rows() }
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak page] rows in
                guard let self, self.revision == revision, let page, self.page === page else { return }
                page.update(rows)
            }
    }

    private func perform(_ action: RoomProfilePollAction) {
        guard isActive else { return }
        switch action {
        case .open(let id):
            guard model.openingEventId != id, let openPoll else { return }
            model.openPoll(id, prepare: openPoll)
        case .cancelOpening(let id):
            if model.openingEventId == id { model.cancelOpening() }
        case .loadMore: model.loadMore()
        case .retryDecryption: model.retryDecryption()
        }
    }
}

final class RoomProfilePollCell: ASCellNode {
    init(poll: RoomProfilePollRow) {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .appBG
        func text(_ value: String, style: UIFont.TextStyle, color: UIColor, lines: UInt) -> ASTextNode {
            let node = ASTextNode()
            node.attributedText = NSAttributedString(string: value, attributes: [
                .font: UIFont.preferredFont(forTextStyle: style), .foregroundColor: color
            ])
            node.maximumNumberOfLines = lines
            node.truncationMode = .byTruncatingTail
            return node
        }
        let question = text(poll.question, style: .body, color: .label, lines: 3)
        let author = text(poll.author, style: .caption1, color: .secondaryLabel, lines: 1)
        let date = text(poll.date, style: .caption1, color: .secondaryLabel, lines: 1)
        let summary = text(poll.summary, style: .caption1,
            color: poll.failedOpening ? .systemRed : (poll.isOpening ? .systemBlue : .secondaryLabel), lines: 2)
        let stacksMetadata = UIFont.preferredFont(forTextStyle: .caption1).lineHeight > 18
        author.style.flexShrink = 1
        date.style.flexShrink = 1
        layoutSpecBlock = { _, range in
            let metadata = ASStackLayoutSpec(direction: stacksMetadata || range.max.width < 360 ? .vertical : .horizontal,
                spacing: 6, justifyContent: .spaceBetween, alignItems: .start, children: [author, date])
            let stack = ASStackLayoutSpec.vertical()
            stack.spacing = 6
            stack.children = [question, metadata, summary]
            return ASInsetLayoutSpec(insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16), child: stack)
        }
        isAccessibilityElement = true
        accessibilityLabel = [poll.question, poll.author, poll.date, poll.summary].joined(separator: ", ")
        accessibilityTraits = .button
    }
}
