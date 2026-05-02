//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

// MARK: - ScanResult

struct ScanResult {
    let images: [UIImage]
    let draftId: UUID?
}

struct DraftRecoveryData {
    let draftId: UUID
    let images: [UIImage]
}

// MARK: - DocumentScannerService Protocol

protocol DocumentScannerService {
    @MainActor
    func scan(from viewController: UIViewController, recovering: DraftRecoveryData?) async throws -> ScanResult
}

// MARK: - ScannerError

enum ScannerError: LocalizedError {
    case cancelled
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Scanning was cancelled"
        case .failed(let error):
            return error.localizedDescription
        }
    }
}
