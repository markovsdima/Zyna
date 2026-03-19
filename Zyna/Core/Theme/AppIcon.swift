//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum AppIcon {
    case play
    case pause
    case stop
    case trash
    case attach
    case send
    case mic
    case lockOpen
    case lockClosed
    case chevronUp

    var systemName: String {
        switch self {
        case .play:       return "play.fill"
        case .pause:      return "pause.fill"
        case .stop:       return "stop.circle.fill"
        case .trash:      return "trash.circle.fill"
        case .attach:     return "paperclip"
        case .send:       return "arrow.up.circle.fill"
        case .mic:        return "mic.fill"
        case .lockOpen:   return "lock.open.fill"
        case .lockClosed: return "lock.fill"
        case .chevronUp:  return "chevron.up"
        }
    }

    func rendered(size: CGFloat = 22, weight: UIImage.SymbolWeight = .medium, color: UIColor) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
        let symbol = UIImage(systemName: systemName, withConfiguration: config)!
        let renderer = UIGraphicsImageRenderer(size: symbol.size)
        return renderer.image { _ in
            symbol.withTintColor(color, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: symbol.size))
        }
    }
}
