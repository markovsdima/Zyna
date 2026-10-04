// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import MatrixRustSDK
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Zyna

@Suite("Matrix link feedback", .serialized)
@MainActor
struct MatrixLinkFeedbackTests {
    @Test("Known API errors use safe, contextual messages and unknown errors never expose SDK details")
    func errors() {
        let forbidden = ClientError.MatrixApi(kind: .forbidden, code: "M_FORBIDDEN", msg: "SECRET", details: "DUMP")
        #expect(MatrixActionFailure.message(for: forbidden, action: .previewRoom)
                == String(localized: "This room is private or does not exist."))
        #expect(MatrixActionFailure.message(for: forbidden, action: .saveTopic)
                == String(localized: "You don't have permission to do this."))
        let unsupported = ClientError.MatrixApi(kind: .unrecognized, code: "M_UNRECOGNIZED", msg: "SECRET", details: nil)
        #expect(MatrixActionFailure.message(for: unsupported, action: .previewRoom)
                == String(localized: "Your server does not support room previews."))
        #expect(MatrixActionFailure.message(for: URLError(.resourceUnavailable), action: .previewRoom)
                == String(localized: "This room is private or does not exist."))
        for action in [MatrixActionFailure.Action.previewRoom, .roomAction, .loadTopic, .saveTopic, .createLink] {
            let message = MatrixActionFailure.message(for: ClientError.Generic(msg: "SECRET", details: "DUMP"), action: action)
            #expect(!message.contains("SECRET") && !message.contains("DUMP") && !message.contains("ClientError"))
        }
    }

    @Test("A copied permalink provides both URL and plain-text representations in one item")
    func clipboard() throws {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        let url = try #require(URL(string: "https://matrix.to/#/!room:example.org/$event?via=example.org"))
        pasteboard.writeLink(url)
        #expect(pasteboard.numberOfItems == 1)
        #expect(pasteboard.url == url && pasteboard.string == url.absoluteString)
        #expect(pasteboard.contains(pasteboardTypes: [UTType.url.identifier]))
        #expect(pasteboard.contains(pasteboardTypes: [UTType.utf8PlainText.identifier]))
    }

    @Test("Copy feedback cannot replace an actionable report banner")
    func bannerPriority() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), center = AppBannerCenter()
        window.rootViewController = UIViewController(); window.isHidden = false
        center.attach(to: window)
        defer { center.dismissAll(); window.isHidden = true; window.rootViewController = nil }
        var actions: [String] = []
        func item(_ id: String, priority: AppBannerPriority = .standard) -> AppBannerItem {
            AppBannerItem(id: id, title: id, icon: .copy, tintColor: .blue, duration: nil,
                priority: priority, onPrimaryAction: { actions.append(id); return .dismiss })
        }
        center.show(item("report"))
        center.show(item("copy", priority: .feedback))
        center.performPrimaryAction()
        #expect(actions == ["report"])
        center.show(item("copy", priority: .feedback))
        center.performPrimaryAction()
        #expect(actions == ["report", "copy"])
    }

    @Test("Cancelling an inline link stops its operation and animation exactly once")
    func openingLifecycle() throws {
        var loading: [Bool] = [], cancels = 0, finishes = 0
        let request = ChatLinkOpening(url: URL(string: "https://matrix.to/#/!room:example.org")!,
            onLoading: { loading.append($0) }, onFinish: { finishes += 1 })
        request.onCancel = { cancels += 1 }
        request.cancel(); request.cancel(); request.setLoading(true)
        #expect(!request.isActive && loading == [true, false] && cancels == 1 && finishes == 1)
    }

    @Test("Another bubble takes over the same link's indicator without restarting its operation", arguments: [false, true])
    func moveIndicator(paused: Bool) {
        var first: [Bool] = [], second: [Bool] = [], cancels = 0
        let request = ChatLinkOpening(url: URL(string: "https://matrix.to/#/!room:example.org")!,
            onLoading: { first.append($0) }, onFinish: {})
        request.onCancel = { cancels += 1 }
        if paused { request.setLoading(false) }
        request.moveLoadingIndicator { second.append($0) }
        #expect(first.last == false && second == [!paused])
        #expect(request.isActive && cancels == 0)
        request.cancel()
        #expect(second == [!paused, false] && cancels == 1)
        request.moveLoadingIndicator { _ in Issue.record("A finished request restored its indicator") }
    }

    @Test("Bubble loading uses one removable layer and never modifies its parent layout")
    func bubbleActivity() {
        let parent = CALayer()
        parent.bounds = CGRect(x: 0, y: 0, width: 240, height: 80)
        let activity = BubbleLinkActivity(parent: parent, color: .blue)
        activity.update(bounds: parent.bounds, path: UIBezierPath(roundedRect: parent.bounds, cornerRadius: 16).cgPath)
        #expect(parent.sublayers?.count == 1 && parent.bounds.width == 240)
        #expect(parent.sublayers?.first?.mask != nil)
        activity.remove()
        #expect(parent.sublayers?.isEmpty != false)
    }

    @Test("Loading recovers lost animations on foreground and visibility changes, but never after completion")
    func bubbleRecovery() throws {
        let parent = CALayer()
        let activity = BubbleLinkActivity(parent: parent, color: .blue)
        let layer = try #require(parent.sublayers?.first as? CAGradientLayer)
        let animates = !UIAccessibility.isReduceMotionEnabled
        #expect((layer.animation(forKey: "linkOpening") != nil) == animates)
        layer.removeAllAnimations()
        #expect(layer.locations == [0, 0.5, 1])
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect((layer.animation(forKey: "linkOpening") != nil) == animates)
        activity.setVisible(false)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(layer.animation(forKey: "linkOpening") == nil)
        activity.setVisible(true)
        #expect((layer.animation(forKey: "linkOpening") != nil) == animates)
        activity.remove()
        activity.setVisible(true)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(layer.animation(forKey: "linkOpening") == nil && layer.superlayer == nil)
    }
}
