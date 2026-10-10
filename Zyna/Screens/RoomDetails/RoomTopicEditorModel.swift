// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import MatrixRustSDK

struct RoomTopicSnapshot: Equatable, Sendable {
    var topic: String
    var canEdit: Bool

    init(topic: String, canEdit: Bool) { self.topic = topic; self.canEdit = canEdit }
    init(_ info: RoomInfo) {
        topic = info.topic ?? ""
        canEdit = !info.isDirect && info.membership == .joined
            && info.powerLevels?.canOwnUserSendState(stateEvent: .roomTopic) == true
    }
}

protocol RoomTopicSource: Sendable {
    func load() async throws -> RoomTopicSnapshot
    func save(_ topic: String) async throws
    func observe(_ update: @escaping @Sendable (RoomTopicSnapshot) -> Void) -> RoomProfileObservation
}

struct SDKRoomTopicSource: RoomTopicSource {
    let room: any RoomProtocol
    func load() async throws -> RoomTopicSnapshot {
        try await Task.detached { RoomTopicSnapshot(try await room.roomInfo()) }.value
    }
    func save(_ topic: String) async throws { try await room.setTopic(topic: topic) }
    func observe(_ update: @escaping @Sendable (RoomTopicSnapshot) -> Void) -> RoomProfileObservation {
        let handle = room.subscribeToRoomInfoUpdates(listener: TopicInfoListener(update))
        return RoomProfileObservation { handle.cancel() }
    }
}

private final class TopicInfoListener: RoomInfoListener {
    private let update: @Sendable (RoomTopicSnapshot) -> Void
    init(_ update: @escaping @Sendable (RoomTopicSnapshot) -> Void) { self.update = update }
    func call(roomInfo: RoomInfo) { update(RoomTopicSnapshot(roomInfo)) }
}

@MainActor
final class RoomTopicEditorModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var snapshot: RoomTopicSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    var onSaved: ((String) -> Void)?

    private let source: any RoomTopicSource
    private let isCurrentSession: () -> Bool
    private var observation: RoomProfileObservation?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var started = false
    private var generation = 0
    private var revision = 0

    init(source: any RoomTopicSource, isCurrentSession: @escaping () -> Bool) {
        self.source = source
        self.isCurrentSession = isCurrentSession
    }

    deinit { readTask?.cancel(); writeTask?.cancel() }

    var canSave: Bool {
        started && isCurrentSession() && !isSaving && !isLoading
            && snapshot?.canEdit == true && normalizedDraft != snapshot?.topic
    }

    private var normalizedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func start() {
        guard !started, isCurrentSession() else { return }
        started = true
        generation += 1
        let generation = generation
        observation = source.observe { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(generation) else { return }
                self.revision += 1
                self.apply(value)
                self.isLoading = false
            }
        }
        reload()
    }

    func reload() {
        guard started, isCurrentSession(), !isSaving else { return }
        readTask?.cancel()
        revision += 1
        let revision = revision, generation = generation, source = source
        isLoading = true
        error = nil
        readTask = Task { [weak self] in
            do {
                let value = try await source.load()
                guard let self, self.accepts(generation), self.revision == revision else { return }
                self.apply(value)
                self.isLoading = false
            } catch {
                guard let self, self.accepts(generation), self.revision == revision else { return }
                self.error = MatrixActionFailure.message(for: error, action: .loadTopic)
                self.isLoading = false
            }
        }
    }

    func save() {
        guard canSave else { return }
        readTask?.cancel()
        revision += 1
        let generation = generation, revision = revision, value = normalizedDraft, source = source
        isSaving = true
        error = nil
        writeTask = Task { [weak self] in
            do {
                let fresh = try await source.load()
                guard let self, self.accepts(generation) else { return }
                if self.revision == revision { self.apply(fresh) }
                guard fresh.canEdit, self.snapshot?.canEdit == true else {
                    self.isSaving = false
                    return
                }
                if value != self.snapshot?.topic { try await source.save(value) }
                guard self.accepts(generation) else { return }
                self.snapshot = RoomTopicSnapshot(topic: value, canEdit: self.snapshot?.canEdit == true)
                self.draft = value
                self.isSaving = false
                self.onSaved?(value)
            } catch {
                guard let self, self.accepts(generation) else { return }
                self.error = MatrixActionFailure.message(for: error, action: .saveTopic)
                self.isSaving = false
            }
        }
    }

    func stop() {
        started = false
        generation += 1
        observation = nil
        readTask?.cancel(); writeTask?.cancel()
        isSaving = false
        isLoading = false
    }

    #if DEBUG
    func waitForOperationsForTesting() async { await readTask?.value; await writeTask?.value }
    #endif

    private func apply(_ value: RoomTopicSnapshot) {
        // Live room updates may replace untouched text, never a local draft.
        let followsRemote = snapshot == nil || draft == snapshot?.topic
        snapshot = value
        if followsRemote && !isSaving { draft = value.topic }
    }

    private func accepts(_ generation: Int) -> Bool {
        started && self.generation == generation && !Task.isCancelled && isCurrentSession()
    }
}
