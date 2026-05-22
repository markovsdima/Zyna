//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

enum SpaceCreationMode: Equatable {
    case storyline
    case track(parent: RoomModel)

    var presentationKind: SpacePresentationKind {
        switch self {
        case .storyline:
            return .storyline
        case .track:
            return .track
        }
    }

    var entityName: String {
        presentationKind.title
    }

    var title: String {
        switch self {
        case .storyline:
            return String(localized: "New Storyline")
        case .track:
            return String(localized: "New Track")
        }
    }

    var createButtonTitle: String {
        switch self {
        case .storyline:
            return String(localized: "Create Storyline")
        case .track:
            return String(localized: "Create Track")
        }
    }

    var errorTitle: String {
        switch self {
        case .storyline:
            return String(localized: "Could not create Storyline")
        case .track:
            return String(localized: "Could not create Track")
        }
    }

    var subtitle: String {
        switch self {
        case .storyline:
            return String(localized: "Storyline")
        case .track:
            return String(localized: "Track")
        }
    }

    var nameLabel: String {
        switch self {
        case .storyline:
            return String(localized: "Storyline Name")
        case .track:
            return String(localized: "Track Name")
        }
    }

    var hint: String {
        switch self {
        case .storyline:
            return String(localized: "Gather related chats and tracks into one Storyline.")
        case .track(let parent):
            let parentName = parent.name.isEmpty ? String(localized: "Untitled") : parent.name
            return String(localized: "Create a Track inside \(parentName) for a focused direction.")
        }
    }

    var addressLabel: String {
        switch self {
        case .storyline:
            return String(localized: "Storyline Address")
        case .track:
            return String(localized: "Track Address")
        }
    }
}

enum SpaceCreationAccess: Equatable {
    case privateInviteOnly
    case publicAnyone

    var isPublic: Bool {
        self == .publicAnyone
    }
}

enum SpacePresentationKind: Equatable {
    case storyline
    case track

    var title: String {
        switch self {
        case .storyline:
            return String(localized: "Storyline")
        case .track:
            return String(localized: "Track")
        }
    }

    var linesPlaceholderText: String {
        switch self {
        case .storyline:
            return String(localized: "Directions within this Storyline will appear here.")
        case .track:
            return String(localized: "Directions within this Track will appear here.")
        }
    }
}
