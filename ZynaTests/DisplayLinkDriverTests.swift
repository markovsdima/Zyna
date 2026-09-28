//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import UIKit
@testable import Zyna

@Suite("Display link frame delivery", .serialized)
@MainActor
struct DisplayLinkDriverTests {
    @Test("Mixed-rate subscribers keep their animation steps and can retain frames")
    func mixedRates() async throws {
        let rates = [15, 30, 60, 120]
        var samples = Array(repeating: [DisplayLinkDriver.Frame](), count: rates.count)
        var maximumRateSamples: [DisplayLinkDriver.Frame] = []
        var capturedFrame: DisplayLinkDriver.Frame?
        var deferredFrame: DisplayLinkDriver.Frame?
        let tokens = rates.enumerated().map { index, fps in
            DisplayLinkDriver.shared.subscribe(rate: .fps(fps)) { frame in
                samples[index].append(frame)
                if fps == 60, capturedFrame == nil {
                    capturedFrame = frame
                    DispatchQueue.main.async {
                        deferredFrame = frame
                    }
                }
            }
        }
        let maximumRateToken = DisplayLinkDriver.shared.subscribe(rate: .max) { frame in
            maximumRateSamples.append(frame)
        }
        defer {
            for token in tokens { token.invalidate() }
            maximumRateToken.invalidate()
        }
        try await Task.sleep(for: .milliseconds(400))

        for (index, fps) in rates.enumerated() {
            let frames = samples[index]
            #expect(!frames.isEmpty, "No callbacks for \(fps) FPS")
            for frame in frames {
                #expect(abs(frame.deltaTime - 1 / Double(fps)) < 1e-10)
                #expect(frame.targetTimestamp > frame.timestamp)
            }
            for (previous, current) in zip(frames, frames.dropFirst()) {
                #expect(current.timestamp - previous.timestamp >= 0.95 / Double(fps))
            }
        }
        #expect(!maximumRateSamples.isEmpty)
        for frame in maximumRateSamples {
            #expect(frame.deltaTime == frame.duration)
        }
        let captured = try #require(capturedFrame)
        let deferred = try #require(deferredFrame)
        #expect(deferred.timestamp == captured.timestamp)
        #expect(deferred.targetTimestamp == captured.targetTimestamp)
        #expect(deferred.deltaTime == captured.deltaTime)
        #expect(deferred.deltaTime == 1 / 60.0)
    }

    @Test("Late capture targets use the display cadence, not the subscriber step")
    func lateCaptureTimestamp() {
        for fps in [60.0, 120.0] {
            let duration = 1 / fps
            let frame = DisplayLinkDriver.Frame(
                timestamp: 10 - duration, targetTimestamp: 10, deltaTime: 1 / 60.0
            )
            #expect(frame.estimatedPresentationTimestamp(at: 9.99) == 10)
            #expect(abs(frame.estimatedPresentationTimestamp(at: 10) - (10 + duration)) < 1e-8)
            // A callback arriving 1/4 frame late targets the next refresh,
            // rather than adding an entire interval to its arrival time.
            #expect(abs(frame.estimatedPresentationTimestamp(at: 10 + duration * 0.25)
                - (10 + duration)) < 1e-8)
            #expect(abs(frame.estimatedPresentationTimestamp(at: 10 + duration * 2.25)
                - (10 + duration * 3)) < 1e-8)
        }
    }
}
