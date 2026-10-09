// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG || CHAT_LIST_PLAYGROUND
import Combine
import Foundation

/// Creates only one outgoing envelope at a time. Pausing leaves that envelope
/// with the ordinary outbox; resuming checks it instead of sending a duplicate.
@MainActor
final class ChatLoadGenerator: ObservableObject {
    struct Configuration: Equatable {
        let count: Int
        let photoEvery: Int
        let interval: TimeInterval

        init(count: Int, photoEvery: Int, interval: TimeInterval) throws {
            guard (1...100_000).contains(count), (0...100_000).contains(photoEvery),
                  interval.isFinite, (0.1...60).contains(interval) else {
                throw Failure("Количество: 1–100 000. Фото: каждые N сообщений (0 — без фото). Интервал: 0,1–60 с.")
            }
            self.count = count
            self.photoEvery = photoEvery
            self.interval = interval
        }

        var photoCount: Int { photoEvery == 0 ? 0 : count / photoEvery }
        func isPhoto(_ number: Int) -> Bool { photoEvery > 0 && number % photoEvery == 0 }
    }

    struct Item {
        // Also supplied to the ordinary sender as its stable Matrix transaction ID.
        let envelopeID: String
        let number: Int
        let isPhoto: Bool
        let body: String
    }

    enum Delivery: Sendable { case missing, waiting, sent, failed }
    enum State: Equatable { case idle, running, paused, finished, failed }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sent = 0
    @Published private(set) var detail = "Сообщения отправятся в этот чат."
    private(set) var configuration: Configuration?
    private(set) var pending: Item?
    /// An enqueue error can happen before or after persistence. Retain the
    /// transaction ID and inspect storage before deciding whether to retry it.
    private var enqueueUnconfirmed = false
    private(set) var runID = ""

    private let validate: () throws -> Void
    private let enqueue: (Item) async throws -> Void
    private let delivery: (String) async throws -> Delivery
    private let sleep: (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?

    init(validate: @escaping () throws -> Void,
         enqueue: @escaping (Item) async throws -> Void,
         delivery: @escaping (String) async throws -> Delivery,
         sleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }) {
        self.validate = validate
        self.enqueue = enqueue
        self.delivery = delivery
        self.sleep = sleep
    }

    func start(_ configuration: Configuration) throws {
        guard state == .idle || state == .finished else { return }
        try validate()
        self.configuration = configuration
        runID = String(UUID().uuidString.prefix(8))
        sent = 0
        pending = nil
        enqueueUnconfirmed = false
        state = .running
        launchIfNeeded()
    }

    func pause() {
        guard state == .running else { return }
        state = .paused
        detail = pending == nil ? "Остановлено. Можно продолжить." : "Остановлено. Последнее сообщение остаётся в очереди отправки."
        // Don't cancel enqueue: it may already have persisted the envelope.
    }

    func resume() throws {
        guard state == .paused || state == .failed else { return }
        try validate()
        state = .running
        launchIfNeeded()
    }

    private func launchIfNeeded() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        defer { task = nil }
        do {
            while state == .running, let configuration {
                try validate()
                if pending == nil {
                    let number = sent + 1
                    let photo = configuration.isPhoto(number)
                    let item = Item(envelopeID: UUID().uuidString, number: number, isPhoto: photo,
                                    body: "[Load \(runID)] \(number)/\(configuration.count) · \(photo ? "Фото" : "Тестовое сообщение для проверки истории и прокрутки.")")
                    pending = item
                    enqueueUnconfirmed = true
                    detail = "Отправка \(number)/\(configuration.count)\(photo ? " · фото" : "")"
                    try await enqueue(item)
                    enqueueUnconfirmed = false
                }
                guard state == .running, let pending else { return }
                let result = try await delivery(pending.envelopeID)
                guard state == .running else { return }
                try validate()
                switch result {
                case .missing:
                    guard enqueueUnconfirmed else {
                        throw Failure("Не найдены ни отправляемое сообщение, ни подтверждение отправки. Генератор остановлен; проверьте чат.")
                    }
                    // A failed enqueue left no envelope or server echo. Retry
                    // the same transaction, never manufacture another identity.
                    try await enqueue(pending)
                    enqueueUnconfirmed = false
                    continue
                case .waiting:
                    enqueueUnconfirmed = false
                    if state == .running {
                        detail = "Ожидаем подтверждение \(pending.number)/\(configuration.count)…"
                    }
                case .sent:
                    sent += 1
                    self.pending = nil
                    if sent == configuration.count {
                        state = .finished
                        detail = "Готово: \(sent) сообщений, из них \(configuration.photoCount) фото."
                        return
                    }
                case .failed:
                    enqueueUnconfirmed = false
                    throw Failure("Сообщение №\(pending.number) не отправлено. Генератор остановлен; проверьте ошибку в чате.")
                }
                guard state == .running else { return }
                // Check pause at least every 250 ms, including long intervals.
                var remaining = self.pending == nil ? configuration.interval : 0.25
                while remaining > 0, state == .running {
                    let slice = min(remaining, 0.25)
                    try await sleep(slice)
                    remaining -= slice
                }
            }
        } catch {
            guard state == .running else { return }
            state = .failed
            detail = error.localizedDescription
        }
    }
}
#endif
