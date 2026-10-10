//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import UIKit
@testable import Zyna

@Suite("Glass capture animation", .serialized)
@MainActor
struct GlassCaptureScaleAnimationTests {
    @MainActor
    private final class Fixture {
        let window: UIWindow
        let view = UIView(frame: CGRect(x: 20, y: 20, width: 200, height: 100))
        let reference = UIView(frame: CGRect(x: 20, y: 140, width: 200, height: 100))

        init() throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.rootViewController = UIViewController()
            window.isHidden = false
            window.rootViewController!.view.addSubview(view)
            window.rootViewController!.view.addSubview(reference)
        }

        func show() async throws {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(60))
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    // Simulate work between adding the animation and committing its transaction.
    private func delayCommit() {
        Thread.sleep(forTimeInterval: 0.12)
    }

    @Test("Prediction uses the resolved start time after a delayed commit")
    func delayedCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.show()
        CATransaction.begin()
        let shrinking = GlassCaptureScaleAnimation(
            view: fixture.view, toScale: 0.92, duration: 1, curve: .easeOut
        )
        defer { shrinking.cancel() }
        let beforeCommit = shrinking.prediction(at: CACurrentMediaTime() + 0.02)
        delayCommit()
        let commitTime = CACurrentMediaTime()
        CATransaction.commit()
        CATransaction.flush()
        #expect(beforeCommit == nil)

        let layer = fixture.view.layer
        let animation = try #require(layer.animationKeys()?.compactMap { layer.animation(forKey: $0) }.first)
        let startTime = layer.convertTime(animation.beginTime, to: nil)
        #expect(startTime >= commitTime)
        let prediction = try #require(shrinking.prediction(at: startTime + 0.5))
        let predictedScale = prediction.transform.a * CGFloat(prediction.layer.transform.m11)
        let expected = 1 - 0.08 * GlassAnimationCurve.easeOut.value(at: 0.5)
        #expect(abs(predictedScale - expected) < 0.0002)
    }

    @Test("Shrink takes over a reply-swipe return without snapping on start or cancellation")
    func overlappingReplySwipe() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for view in [fixture.view, fixture.reference] {
            view.transform = CGAffineTransform(translationX: -64, y: 0)
        }
        try await fixture.show()
        for view in [fixture.view, fixture.reference] {
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.82,
                           initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                view.transform = .identity
            }
        }
        try await fixture.show()
        let beforeShrink = try #require(fixture.view.layer.presentation()).transform
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0.8
        opacity.duration = 1
        fixture.view.layer.add(opacity, forKey: "test-opacity")
        let shrinking = GlassCaptureScaleAnimation(
            view: fixture.view, toScale: 0.92, duration: 0.25, curve: .easeOut,
            fromTransform: beforeShrink
        )
        defer { shrinking.cancel() }
        CATransaction.flush()
        let actual = try #require(fixture.view.layer.presentation()).transform
        #expect(beforeShrink.m41 < -10)
        #expect(abs(actual.m41 - beforeShrink.m41) < 1)
        #expect(fixture.view.layer.animation(forKey: "test-opacity") != nil)
        let transforms = fixture.view.layer.animationKeys()?.compactMap {
            fixture.view.layer.animation(forKey: $0) as? CAPropertyAnimation
        }.filter { $0.keyPath == "transform" }
        #expect(transforms?.count == 1)

        try await fixture.show()
        let beforeCancel = try #require(fixture.view.layer.presentation()).transform
        #expect(beforeCancel.m11 < 1 && beforeCancel.m11 > 0.92)
        #expect(beforeCancel.m41 > beforeShrink.m41 && beforeCancel.m41 < 0)
        let frozen = try #require(shrinking.cancel())
        #expect(abs(frozen.m11 - beforeCancel.m11) < 0.002)
        #expect(abs(frozen.m41 - beforeCancel.m41) < 1)
        let returning = GlassCaptureScaleAnimation(
            view: fixture.view, toScale: 1, duration: 0.2, curve: .easeInOut,
            fromTransform: frozen
        )
        defer { returning.cancel() }
        CATransaction.flush()
        let afterCancel = try #require(fixture.view.layer.presentation()).transform
        #expect(abs(afterCancel.m41 - beforeCancel.m41) < 1)
        #expect(abs(afterCancel.m11 - beforeCancel.m11) < 0.002)
        #expect(abs(fixture.view.transform.tx) < 0.001)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.view.transform.isIdentity)
    }

    @Test("Capture easing matches Core Animation's presentation scale")
    func predictionEasing() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.show()
        for curve in [GlassAnimationCurve.easeOut, .easeInOut] {
            for progress in [0.1, 0.5, 0.9] {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = CATransform3DIdentity
                animation.toValue = CATransform3DMakeScale(0.92, 0.92, 1)
                animation.duration = 1
                animation.speed = 0
                animation.timeOffset = progress
                animation.timingFunction = curve.timingFunction
                fixture.view.layer.add(animation, forKey: "test-easing")
                try await fixture.show()
                let actual = try #require(fixture.view.layer.presentation()).transform.m11
                let expected = 1 - 0.08 * curve.value(at: progress)
                #expect(abs(actual - expected) < 0.0002)
            }
        }
    }

    @Test("Prediction ends on cancellation, reparenting, and completion")
    func predictionLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.show()
        var completions: [Bool] = []
        let shrinking = GlassCaptureScaleAnimation(
            view: fixture.view, toScale: 0.92, duration: 1, curve: .easeOut
        ) { completions.append($0) }
        try await fixture.show()
        #expect(shrinking.prediction(at: CACurrentMediaTime() + 0.02) != nil)

        fixture.reference.addSubview(fixture.view)
        #expect(shrinking.prediction(at: CACurrentMediaTime() + 0.02) == nil)
        fixture.window.rootViewController!.view.addSubview(fixture.view)
        shrinking.cancel()
        #expect(shrinking.prediction(at: CACurrentMediaTime() + 0.02) == nil)
        #expect(completions == [false])
        #expect(fixture.view.transform.a > 0.92)

        let returning = GlassCaptureScaleAnimation(
            view: fixture.view, toScale: 1, duration: 0.05, curve: .easeInOut
        ) { completions.append($0) }
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(200))
        #expect(completions == [false, true])
        #expect(returning.prediction(at: CACurrentMediaTime() + 0.02) == nil)
        #expect(fixture.view.transform.isIdentity)
    }
}
