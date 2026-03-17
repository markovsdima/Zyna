//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import QuartzCore

// MARK: - Rate

/// Requested frame rate for DisplayLink subscriptions.
public struct DisplayLinkRate: Comparable, Hashable, Sendable {
    fileprivate let value: Int?

    private init(value: Int?) {
        self.value = value
    }

    public static func fps(_ value: Int) -> DisplayLinkRate {
        DisplayLinkRate(value: value)
    }

    public static let max = DisplayLinkRate(value: nil)

    public static func < (lhs: DisplayLinkRate, rhs: DisplayLinkRate) -> Bool {
        switch (lhs.value, rhs.value) {
        case (nil, nil):
            return false
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (l?, r?):
            return l < r
        }
    }
}

extension DisplayLinkRate: CustomStringConvertible {
    public var description: String {
        value.map { "fps(\($0))" } ?? "max"
    }
}

private extension DisplayLinkRate {
    var frameInterval: CFTimeInterval? {
        value.map { 1.0 / CFTimeInterval($0) }
    }

    var wantsHighRefresh: Bool {
        switch value {
        case nil:
            return true
        case let v?:
            return v > 60
        }
    }
}

// MARK: - Token

/// Subscription token for DisplayLinkDriver.
/// Holds the subscription active while retained. Release to automatically unsubscribe.
public final class DisplayLinkToken {
    fileprivate weak var driver: DisplayLinkDriver?
    fileprivate let rate: DisplayLinkRate
    fileprivate let tick: ((CFTimeInterval) -> Void)?

    fileprivate var isPaused: Bool = false
    fileprivate var isValid: Bool = true

    fileprivate init(
        driver: DisplayLinkDriver,
        rate: DisplayLinkRate,
        tick: ((CFTimeInterval) -> Void)?
    ) {
        self.driver = driver
        self.rate = rate
        self.tick = tick
    }

    /// Pause this subscription (stops receiving ticks, but keeps the subscription).
    public func pause() {
        isPaused = true
        if Thread.isMainThread {
            driver?.setNeedsStateUpdate()
        }
    }

    /// Resume a paused subscription.
    public func resume() {
        isPaused = false
        if Thread.isMainThread {
            driver?.setNeedsStateUpdate()
        }
    }

    /// Invalidate and remove this subscription.
    public func invalidate() {
        isValid = false
        isPaused = true
        driver?.setNeedsStateUpdate()
        driver = nil
    }
}

// MARK: - DisplayLinkDriver

/// Shared CADisplayLink manager for the entire application.
/// Provides a single CADisplayLink instance with multiple subscribers at different frame rates.
public final class DisplayLinkDriver {

    // MARK: - Subscription Entry

    private final class SubscriptionEntry {
        weak var token: DisplayLinkToken?
        var lastTickTime: CFTimeInterval = 0

        init(token: DisplayLinkToken) {
            self.token = token
        }
    }

    // MARK: - Singleton

    public static let shared = DisplayLinkDriver()

    // MARK: - Private Properties

    private let log = ScopedLog(.displayLink, prefix: "[DisplayLink]")
    private var displayLink: CADisplayLink?
    private var subscriptions: [SubscriptionEntry] = []

    private var isInForeground: Bool = true
    private var isProcessingTick: Bool = false
    private var needsStateUpdate: Bool = false

    private var fpsLastTimestamp: CFTimeInterval = 0
    private var fpsFrameCount: Int = 0

    private let isProMotionSupported: Bool = {
        UIScreen.main.maximumFramesPerSecond > 60
    }()

    // MARK: - Init

    private init() {
        // Determine initial foreground state
        switch UIApplication.shared.applicationState {
        case .active, .inactive:
            isInForeground = true
        case .background:
            isInForeground = false
        @unknown default:
            isInForeground = true
        }

        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isInForeground = true
            self?.performStateUpdate()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isInForeground = false
            self?.performStateUpdate()
        }
    }

    // MARK: - Public API

    /// Subscribe to shared CADisplayLink ticks.
    /// - Parameters:
    ///   - rate: Requested frame rate for this subscriber.
    ///   - tick: Optional callback invoked on main thread for each frame. Pass nil for silent rate requests.
    /// - Returns: Token that holds the subscription. Release to automatically unsubscribe.
    @discardableResult
    public func subscribe(
        rate: DisplayLinkRate = .fps(60),
        tick: ((CFTimeInterval) -> Void)? = nil
    ) -> DisplayLinkToken {
        let token = DisplayLinkToken(
            driver: self,
            rate: rate,
            tick: tick
        )

        subscriptions.append(SubscriptionEntry(token: token))
        log("subscribe rate=\(rate) tick=\(tick != nil)")
        performStateUpdate()

        return token
    }

    // MARK: - Internal

    fileprivate func setNeedsStateUpdate() {
        if isProcessingTick {
            needsStateUpdate = true
        } else {
            performStateUpdate()
        }
    }

    // MARK: - Private

    private func performStateUpdate() {
        var hasActiveItems = false
        var maxRate: DisplayLinkRate?

        var indicesToRemove: [Int]?

        for i in 0..<subscriptions.count {
            let entry = subscriptions[i]

            guard let token = entry.token, token.isValid else {
                if indicesToRemove == nil {
                    indicesToRemove = [i]
                } else {
                    indicesToRemove?.append(i)
                }
                continue
            }

            guard !token.isPaused else { continue }
            hasActiveItems = true
            if let currentMax = maxRate {
                if token.rate > currentMax {
                    maxRate = token.rate
                }
            } else {
                maxRate = token.rate
            }
        }

        if let indicesToRemove {
            for index in indicesToRemove.reversed() {
                subscriptions.remove(at: index)
            }
        }

        if isInForeground && hasActiveItems, let maxRate {
            ensureDisplayLinkRunning()
            updateFrameRateRange(frameRateRange(for: maxRate))
        } else {
            stopDisplayLink()
        }
    }

    private func ensureDisplayLinkRunning() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
        fpsLastTimestamp = 0
        fpsFrameCount = 0
        //log("displayLink start")
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        fpsLastTimestamp = 0
        fpsFrameCount = 0
        //log("displayLink stop")
    }

    private func updateFrameRateRange(_ range: CAFrameRateRange) {
        guard let displayLink, isProMotionSupported else { return }

        if displayLink.preferredFrameRateRange != range {
            displayLink.preferredFrameRateRange = range
            log("switch to \(range)")
        }
    }

    private func frameRateRange(for rate: DisplayLinkRate) -> CAFrameRateRange {
        guard rate.wantsHighRefresh else { return .default }
        return CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        isProcessingTick = true
        defer {
            isProcessingTick = false
            if needsStateUpdate {
                needsStateUpdate = false
                performStateUpdate()
            }
        }

        let currentTime = link.timestamp
        let frameDuration = link.targetTimestamp - link.timestamp
        //logCurrentFPS(currentTime)

        var indicesToRemove: [Int]?

        for i in 0..<subscriptions.count {
            let entry = subscriptions[i]

            guard let token = entry.token, token.isValid else {
                // Token was deallocated — mark for removal
                if indicesToRemove == nil {
                    indicesToRemove = [i]
                } else {
                    indicesToRemove?.append(i)
                }
                continue
            }

            guard !token.isPaused, let tick = token.tick else { continue }

            if let interval = token.rate.frameInterval {
                let elapsed = currentTime - entry.lastTickTime
                guard elapsed >= interval * 0.95 else { continue }
                entry.lastTickTime = currentTime
                tick(interval)
            } else {
                tick(frameDuration)
            }
        }

        // Cleanup deallocated subscriptions
        if let indicesToRemove {
            for index in indicesToRemove.reversed() {
                subscriptions.remove(at: index)
            }
            if subscriptions.isEmpty {
                needsStateUpdate = true
            }
        }
    }

    private func logCurrentFPS(_ timestamp: CFTimeInterval) {
#if DEBUG
        fpsFrameCount += 1

        if fpsLastTimestamp == 0 {
            fpsLastTimestamp = timestamp
            return
        }

        let delta = timestamp - fpsLastTimestamp
        if delta >= 1.0 {
            let fps = Double(fpsFrameCount) / delta
            let formattedFPS = String(format: "%.1f", fps)
            log("fps=\(formattedFPS)")
            fpsFrameCount = 0
            fpsLastTimestamp = timestamp - delta.remainder(dividingBy: 1.0)
        }
#endif
    }
}

// MARK: - Debug

#if DEBUG
public extension DisplayLinkDriver {
    var activeSubscriptionsCount: Int {
        subscriptions.filter { entry in
            guard let token = entry.token else { return false }
            return !token.isPaused
        }.count
    }
    var totalSubscriptionsCount: Int { subscriptions.count }
}
#endif
