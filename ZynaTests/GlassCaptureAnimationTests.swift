//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import UIKit
@testable import Zyna

@Suite("Glass capture animation lifecycle", .serialized)
@MainActor
struct GlassCaptureAnimationTests {
    /// Store CA copies without delivering stop callbacks. This lets the test
    /// order removal, cancellation, and a late completion deterministically.
    private final class DeferredStopLayer: CALayer {
        private var storedAnimations: [String: CAAnimation] = [:]

        override func add(_ anim: CAAnimation, forKey key: String?) {
            guard let key else { preconditionFailure("The test requires an animation key") }
            storedAnimations[key] = anim.copy() as? CAAnimation
        }

        override func animation(forKey key: String) -> CAAnimation? {
            storedAnimations[key]?.copy() as? CAAnimation
        }

        override func animationKeys() -> [String]? {
            Array(storedAnimations.keys)
        }

        override func removeAnimation(forKey key: String) {
            storedAnimations.removeValue(forKey: key)
        }
    }

    private final class DeferredStopView: UIView {
        override class var layerClass: AnyClass { DeferredStopLayer.self }
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let bubble = UIView(frame: CGRect(x: 20, y: 20, width: 200, height: 100))
        let viewport = UIView(frame: CGRect(x: 20, y: 140, width: 200, height: 100))

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.rootViewController = UIViewController()
            window.isHidden = false
            window.rootViewController!.view.addSubview(bubble)
            window.rootViewController!.view.addSubview(viewport)
        }

        func settle() async throws {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(60))
        }

        func predictions(for view: UIView) -> [GlassCapturePrediction] {
            GlassCaptureAnimation.predictions(at: CACurrentMediaTime() + 0.02)
                .filter { $0.matches(view.layer) }
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @Test("One registry samples both motions and preserves their different stop behavior")
    func mixedMotions() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.settle()
        let scale = GlassCaptureScaleAnimation(
            view: fixture.bubble, toScale: 0.92, duration: 1, curve: .easeOut
        )
        let destination = CGRect(x: 20, y: 400, width: 200, height: 300)
        let viewport = GlassCaptureViewportAnimation(view: fixture.viewport, to: destination, duration: 1)
        defer { scale.cancel(); viewport.stop() }
        try await fixture.settle()
        #expect(fixture.predictions(for: fixture.bubble).count == 1)
        #expect(fixture.predictions(for: fixture.viewport).count == 1)

        fixture.viewport.addSubview(fixture.bubble)
        #expect(fixture.predictions(for: fixture.bubble).isEmpty)
        #expect(fixture.predictions(for: fixture.viewport).count == 1)
        fixture.window.rootViewController!.view.addSubview(fixture.bubble)
        let frozen = try #require(scale.cancel())
        #expect(frozen.m11 > 0.92 && frozen.m11 < 1)
        #expect(fixture.bubble.layer.transform.m11 == frozen.m11)
        viewport.stop()
        #expect(fixture.viewport.frame == destination)
        #expect(fixture.predictions(for: fixture.bubble).isEmpty)
        #expect(fixture.predictions(for: fixture.viewport).isEmpty)
    }

    @Test("Cancellation completes once and can start a successor under the same key")
    func successorFromCompletion() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.settle()
        var completions: [Bool] = []
        var returning: GlassCaptureScaleAnimation?
        let shrinking = GlassCaptureScaleAnimation(
            view: fixture.bubble, toScale: 0.92, duration: 1, curve: .easeOut
        ) { finished in
            completions.append(finished)
            returning = GlassCaptureScaleAnimation(
                view: fixture.bubble, toScale: 1, duration: 1, curve: .easeInOut,
                fromTransform: fixture.bubble.layer.transform
            ) { completions.append($0) }
        }
        defer { shrinking.cancel(); returning?.cancel() }
        try await fixture.settle()
        let frozen = try #require(shrinking.cancel())
        #expect(frozen.m11 > 0.92 && frozen.m11 < 1)
        #expect(completions == [false])
        #expect(shrinking.cancel() == nil)
        try await fixture.settle()
        #expect(returning?.prediction(at: CACurrentMediaTime() + 0.02) != nil)
        #expect(fixture.predictions(for: fixture.bubble).count == 1)
        #expect(completions == [false])
        returning?.cancel()
        returning?.cancel()
        try await fixture.settle()
        #expect(completions == [false, false])
        #expect(fixture.predictions(for: fixture.bubble).isEmpty)
    }

    @Test("Cancel retires shrink after removal even if its successful stop arrives late",
          arguments: [false, true])
    func delayedShrinkCompletion(replaceBeforeCancel: Bool) throws {
        let view = DeferredStopView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        var completions: [Bool] = []
        let shrinking = GlassCaptureScaleAnimation(
            view: view, toScale: 0.92, duration: 0.25, curve: .easeOut
        ) { completions.append($0) }
        let key = try #require(view.layer.animationKeys()?.first)
        let removed = try #require(view.layer.animation(forKey: key))
        let delegate = try #require(removed.delegate)
        view.layer.removeAnimation(forKey: key)
        #expect(completions.isEmpty)

        var returning: GlassCaptureScaleAnimation?
        defer { shrinking.cancel(); returning?.cancel() }
        func startReturn() -> GlassCaptureScaleAnimation {
            GlassCaptureScaleAnimation(view: view, toScale: 1, duration: 0.2, curve: .easeInOut)
        }
        if replaceBeforeCancel { returning = startReturn() }
        let modelTransform = view.layer.transform
        #expect(shrinking.cancel() == nil)
        #expect(completions == [false])
        #expect(CATransform3DEqualToTransform(view.layer.transform, modelTransform))
        if !replaceBeforeCancel { returning = startReturn() }
        let successor = try #require(view.layer.animation(forKey: key))
        #expect(successor.delegate !== delegate)

        delegate.animationDidStop?(removed, finished: true)
        #expect(shrinking.cancel() == nil)
        #expect(completions == [false])
        #expect(view.layer.animation(forKey: key)?.delegate === successor.delegate)
        #expect(view.transform.isIdentity)
    }

    @Test("Stopping a replaced viewport handle leaves its successor running")
    func replacedViewport() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.settle()
        let first = GlassCaptureViewportAnimation(
            view: fixture.viewport, to: CGRect(x: 20, y: 400, width: 200, height: 300), duration: 1
        )
        try await fixture.settle()
        let second = GlassCaptureViewportAnimation(
            view: fixture.viewport, to: CGRect(x: 20, y: 200, width: 200, height: 200), duration: 1
        )
        defer { first.stop(); second.stop() }
        // The old CA delegate may not have delivered its stop callback yet.
        first.stop()
        first.stop()
        try await fixture.settle()
        #expect(first.prediction(at: CACurrentMediaTime() + 0.02) == nil)
        #expect(second.prediction(at: CACurrentMediaTime() + 0.02) != nil)
        #expect(fixture.predictions(for: fixture.viewport).count == 1)
        second.stop()
        #expect(fixture.predictions(for: fixture.viewport).isEmpty)
    }
}
