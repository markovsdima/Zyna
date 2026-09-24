//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import UIKit
@testable import Zyna

@Suite("Glass viewport prediction", .serialized)
@MainActor
struct GlassCaptureViewportAnimationTests {
    @Test("Predicted position and bounds match a paused CA group at the target display time")
    func matchesCoreAnimation() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let host = window.rootViewController!.view!
        let viewport = UIScrollView(frame: CGRect(x: 20, y: 80, width: 200, height: 60))
        viewport.contentInsetAdjustmentBehavior = .never
        viewport.contentSize = CGSize(width: 200, height: 500)
        viewport.contentOffset.y = 180
        let reference = UIView()
        reference.bounds = viewport.bounds
        reference.layer.position = viewport.layer.position
        host.addSubview(viewport)
        host.addSubview(reference)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(60))
        let motion = GlassCaptureViewportAnimation(
            view: viewport, to: CGRect(x: 20, y: 20, width: 200, height: 350), duration: 10
        )
        defer { motion.stop() }
        CATransaction.flush()
        let group = try #require(viewport.layer.animationKeys()?.compactMap {
            viewport.layer.animation(forKey: $0) as? CAAnimationGroup
        }.first)
        #expect(group.beginTime > 0)
        for progress in [0.1, 0.5, 0.9] {
            let paused = try #require(group.copy() as? CAAnimationGroup)
            paused.delegate = nil
            paused.beginTime = 0
            paused.speed = 0
            paused.timeOffset = group.duration * progress
            reference.layer.add(paused, forKey: "reference")
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(60))
            let target = viewport.layer.convertTime(group.beginTime + group.duration * progress, to: nil)
            let prediction = try #require(motion.prediction(at: target))
            let actual = try #require(reference.layer.presentation())
            #expect(abs(prediction.bounds.minY - actual.bounds.minY) < 0.002)
            #expect(abs(prediction.bounds.height - actual.bounds.height) < 0.002)
            let predictedFrame = prediction.layer.convert(
                prediction.bounds.applying(prediction.transform), to: host.layer.presentation()
            )
            #expect(abs(predictedFrame.minY - actual.frame.minY) < 0.002)
            #expect(abs(predictedFrame.height - actual.frame.height) < 0.002)
        }
        reference.addSubview(viewport)
        #expect(motion.prediction(at: CACurrentMediaTime() + 0.01) == nil)
        host.addSubview(viewport)
        motion.stop()
        #expect(motion.prediction(at: CACurrentMediaTime() + 0.01) == nil)
    }

    @Test("A completed return no longer contributes capture predictions")
    func completion() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let viewport = UIView(frame: CGRect(x: 20, y: 20, width: 100, height: 100))
        window.rootViewController!.view.addSubview(viewport)
        let destination = viewport.frame.offsetBy(dx: 0, dy: 100)
        let motion = GlassCaptureViewportAnimation(view: viewport, to: destination, duration: 0.03)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(160))
        #expect(motion.prediction(at: CACurrentMediaTime() + 0.01) == nil)
        #expect(GlassCaptureAnimation.predictions(at: CACurrentMediaTime() + 0.01).isEmpty)
        #expect(viewport.frame == destination)
    }
}
