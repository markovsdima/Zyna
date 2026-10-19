// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Combine
import Foundation
import MatrixRustSDK
import UIKit

enum MatrixLinkTarget: Sendable {
    case person(String)
    case room(any RoomProtocol)
    case event(room: any RoomProtocol, eventID: String)

    func url() async throws -> URL {
        let worker = Task.detached {
            switch self {
            case .person(let id): return try matrixToUserPermalink(userId: id)
            case .room(let room): return try await room.matrixToPermalink()
            case .event(let room, let eventID): return try await room.matrixToEventPermalink(eventId: eventID)
            }
        }
        let value = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard let url = URL(string: value), url.scheme == "https", url.host == "matrix.to" else {
            throw URLError(.badURL)
        }
        return url
    }
}

@MainActor
final class MatrixLinkSharing: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published var error: String?
    private let isCurrentSession: () -> Bool
    private let resolve: @Sendable (MatrixLinkTarget) async throws -> URL
    private var task: Task<Void, Never>?
    private var generation = 0

    init(isCurrentSession: @escaping () -> Bool,
         resolve: @escaping @Sendable (MatrixLinkTarget) async throws -> URL = { try await $0.url() }) {
        self.isCurrentSession = isCurrentSession
        self.resolve = resolve
    }

    static func forCurrentSession() -> MatrixLinkSharing {
        let client = MatrixClientService.shared.client
        let session = MatrixClientService.shared.currentLocalSessionId
        return MatrixLinkSharing(isCurrentSession: {
            client != nil && session != nil && MatrixClientService.shared.client === client
                && MatrixClientService.shared.currentLocalSessionId == session
        })
    }

    static func copyToPasteboard(_ url: URL) {
        UIPasteboard.general.writeLink(url)
        UISelectionFeedbackGenerator().selectionChanged()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Link copied"))
        AppBannerCenter.shared.show(AppBannerItem(id: "matrix.link.copied",
            title: String(localized: "Link copied"), icon: .copy,
            tintColor: AppColor.accent, duration: 2, priority: .feedback,
            onPrimaryAction: { .dismiss }))
    }

    deinit { task?.cancel() }

    func prepare(_ target: MatrixLinkTarget, replacingPending: Bool = false, completion: @escaping (URL) -> Void) {
        guard !isPreparing || replacingPending, isCurrentSession() else { return }
        generation += 1
        task?.cancel()
        let generation = generation, resolve = resolve
        isPreparing = true
        error = nil
        task = Task { [weak self] in
            do {
                let url = try await resolve(target)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.isPreparing = false
                guard self.isCurrentSession() else { return }
                completion(url)
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.isPreparing = false
                guard self.isCurrentSession() else { return }
                self.error = MatrixActionFailure.message(for: error, action: .createLink)
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        isPreparing = false
    }

    #if DEBUG
    var operationForTesting: Task<Void, Never>? { task }
    func waitForOperationForTesting() async { await task?.value }
    #endif
}
