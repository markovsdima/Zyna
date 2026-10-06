//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum AttachmentDownloadEvent {
    /// 0…1, or -1 when the SDK reports no progress.
    case progress(Double)
    case finished
    case failed(String)
}

/// Presentation stays with the coordinator; attachment pages report taps
/// and receive download events back.
struct RoomAttachmentsActions {
    var openImages: (_ items: [ImageViewerController.Item], _ initialIndex: Int) -> Void
    var openVideo: (
        _ item: AttachmentItem,
        _ previewImage: UIImage?,
        _ sourceFrame: CGRect,
        _ onEvent: @escaping (AttachmentDownloadEvent) -> Void
    ) -> Void
    var openFile: (_ item: AttachmentItem, _ onEvent: @escaping (AttachmentDownloadEvent) -> Void) -> Void
    #if DEBUG
    var openPoll: @MainActor (_ eventId: String) async throws -> PreparedPollNavigation = { _ in
        throw PollNavigationError.unavailable
    }
    #endif

    static let none = RoomAttachmentsActions(
        openImages: { _, _ in },
        openVideo: { _, _, _, _ in },
        openFile: { _, _ in }
    )
}
