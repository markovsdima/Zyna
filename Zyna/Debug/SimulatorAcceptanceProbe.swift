// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG
import UIKit
import MatrixRustSDK
import Darwin

/// Opt-in device/simulator instrumentation. No account IDs, event IDs or contents.
/// Keeps weak object references and writes one sample per second off main.
@MainActor
enum SimulatorAcceptanceProbe {
    private final class WeakEntry {
        weak var object: AnyObject?
        let kind: String
        init(_ object: AnyObject, _ kind: String) { self.object = object; self.kind = kind }
    }
    private static var watched: [ObjectIdentifier: WeakEntry] = [:]
    private static var task: Task<Void, Never>?
    private static let writer = DispatchQueue(label: "zyna.simulator.acceptance")
    private static let label = UILabel()
    private static let gestureSurface = UILabel()
    private static var controlTargets: [String: UILabel] = [:]
    private static var output: URL?
    private static var started = 0.0
    private static var previousCPU: (wall: Double, cpu: Double)?
    private static let session = UUID().uuidString
    private static var pairedImageID: String?
    private static var closureReactionAttempts: [[String: Any]] = []
    private static var closureReactionTargets: [String: String] = [:]
    private static var closureReactionTransport: [[String: Any]] = []
    static let tracesDeletion = ProcessInfo.processInfo.environment["ZYNA_DELETE_TRACE"] == "1"
    private static var deletionOutput: URL?

    static func recordClosureReactionAttempt(_ message: ChatMessage, key: String, prepared: Bool) {
        guard output != nil, let marker = ProcessInfo.processInfo.environment["ZYNA_CLOSURE_MARKER"],
              marker.hasPrefix("Zyna acceptance "),
              let slot = ["even", "odd"].first(where: { message.content.textPreview == marker + " " + $0 }) else { return }
        closureReactionAttempts.append(["epoch": Date().timeIntervalSince1970, "slot": slot,
            "capturedOwn": message.reactions.contains { $0.key == key && $0.isOwn },
            "capturedPendingRemoval": message.reactions.contains { $0.key == key && $0.isPendingRemoval },
            "prepared": prepared])
        if closureReactionAttempts.count > 32 { closureReactionAttempts.removeFirst() }
    }

    static func recordClosureReactionTransport(target: String, outcome: String) {
        guard output != nil, let slot = closureReactionTargets[target] else { return }
        closureReactionTransport.append(["epoch": Date().timeIntervalSince1970, "slot": slot, "outcome": outcome])
        if closureReactionTransport.count > 32 { closureReactionTransport.removeFirst() }
    }

    static func recordDeletion(_ state: [String: Any]) {
        guard tracesDeletion, let deletionOutput else { return }
        var value = state
        value["session"] = session
        if value["epoch"] == nil { value["epoch"] = Date().timeIntervalSince1970 }
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        writer.async {
            guard let handle = try? FileHandle(forWritingTo: deletionOutput) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes + Data([10]))
        }
    }

    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ZYNA_ACCEPTANCE"] == "1" || environment["ZYNA_SIM_ACCEPTANCE"] == "1",
              task == nil else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simulator-acceptance.jsonl")
        output = url
        started = ProcessInfo.processInfo.systemUptime
        UIDevice.current.isBatteryMonitoringEnabled = true
        try? Data().write(to: url)
        if tracesDeletion {
            deletionOutput = url.deletingLastPathComponent().appendingPathComponent("deletion-trace.jsonl")
            try? Data().write(to: deletionOutput!)
        }
        label.accessibilityIdentifier = "acceptance.status"
        label.isAccessibilityElement = true
        label.isUserInteractionEnabled = false
        label.font = .monospacedSystemFont(ofSize: 5, weight: .regular)
        label.textColor = .secondaryLabel
        gestureSurface.accessibilityIdentifier = "acceptance.mediaGesture"
        gestureSurface.accessibilityLabel = "Media gesture coordinates"
        gestureSurface.isAccessibilityElement = true
        gestureSurface.isUserInteractionEnabled = false
        task = Task {
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static func watch(_ object: AnyObject, kind: String) {
        let id = ObjectIdentifier(object)
        if watched[id]?.object == nil { watched[id] = WeakEntry(object, kind) }
    }

    private static func sample() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }), let root = window.rootViewController else { return }
        var controllers: [UIViewController] = []
        func visit(_ vc: UIViewController) {
            controllers.append(vc)
            vc.children.forEach(visit)
            if let presented = vc.presentedViewController { visit(presented) }
        }
        visit(root)
        var top = root
        while true {
            if let presented = top.presentedViewController { top = presented }
            else if let tabs = top as? ZynaTabBarController, let selected = tabs.selectedController { top = selected }
            else if let nav = top as? ZynaNavigationController, let selected = nav.topViewController { top = selected }
            else if let route = top as? ChatRouteViewController, let chat = route.chat { top = chat }
            else { break }
        }
        var value: [String: Any] = ["epoch": Date().timeIntervalSince1970, "session": session,
            "elapsed": ProcessInfo.processInfo.systemUptime - started, "sdk": sdkGitSha(),
            "screen": String(describing: type(of: top)), "footprint": footprint()]
        value["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
        value["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        value["batteryLevel"] = UIDevice.current.batteryLevel
        value["batteryState"] = UIDevice.current.batteryState.rawValue
        value["osVersion"] = UIDevice.current.systemVersion
        value["buildConfiguration"] = "Debug"
        #if targetEnvironment(simulator)
        value["platform"] = "simulator"
        #else
        value["platform"] = "device"
        #endif
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
                Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            let wall = ProcessInfo.processInfo.systemUptime
            value["cpuSeconds"] = cpu
            if let previousCPU, wall > previousCPU.wall, cpu >= previousCPU.cpu {
                // 100% is one fully occupied CPU core, not the whole device.
                value["cpuPercent"] = 100 * (cpu - previousCPU.cpu) / (wall - previousCPU.wall)
            }
            previousCPU = (wall, cpu)
        }
        gestureSurface.isHidden = true
        controlTargets.values.forEach { $0.isHidden = true }
        for vc in controllers {
            if let chat = vc as? ChatViewController {
                if tracesDeletion {
                    value["deletion"] = chat.simulatorAcceptanceTraceDeletion("sample", readDatabase: true)
                }
                chat.simulatorAcceptanceExposeEditor()
                let images = chat.simulatorAcceptanceExposeImages()
                if let marker = ProcessInfo.processInfo.environment["ZYNA_PAIR_MARKER"] {
                    if pairedImageID == nil {
                        pairedImageID = images.first(where: { $0.caption == marker + " photo 0" })?.id
                    }
                    if let pairedImageID {
                        let modelImage = chat.simulatorAcceptanceModel.messages.first(where: { $0.id == pairedImageID })
                        value["pairedImageModelState"] = modelImage == nil ? "absent"
                            : modelImage?.content.isRedacted == true ? "redacted" : "present"
                        let caption = images.first(where: { $0.id == pairedImageID })?.caption
                        // Only fixed fixture states enter metrics, never IDs or contents.
                        value["pairedImageState"] = caption == nil ? "absent"
                            : caption == "" ? "empty"
                            : caption == marker + " photo 0" ? "caption0"
                            : caption == marker + " photo 1" ? "caption1" : "other"
                    }
                }
                watch(chat, kind: "chat"); watch(chat.simulatorAcceptanceModel, kind: "chatModel")
                watch(chat.simulatorAcceptanceModel.simulatorAcceptanceBatcher, kind: "ingestionBatcher")
                watch(chat.simulatorAcceptanceModel.simulatorAcceptanceBatcher.ingestionMetrics, kind: "ingestionMetrics")
                if let timeline = chat.simulatorAcceptanceModel.liveTimelineService { watch(timeline, kind: "chatTimeline") }
                value["chatRows"] = chat.simulatorAcceptanceModel.rows.count
                value["chatMessages"] = chat.simulatorAcceptanceModel.messages.count
                if let marker = ProcessInfo.processInfo.environment["ZYNA_CLOSURE_MARKER"],
                   marker.hasPrefix("Zyna acceptance ") {
                    // Only these test-owned slots enter diagnostics; no body or ID is written.
                    var fixtures: [String: Any] = [:]
                    for slot in ["even", "odd", "done", "offline", "received"] {
                        let matches = chat.simulatorAcceptanceModel.messages.filter {
                            $0.content.textPreview == marker + " " + slot
                        }
                        for message in matches {
                            if let id = message.eventId { closureReactionTargets[id] = slot }
                        }
                        var fixture: [String: Any] = ["count": matches.count]
                        fixture["outgoing"] = matches.filter(\.isOutgoing).count
                        fixture["remote"] = matches.filter { $0.eventId != nil }.count
                        fixture["read"] = matches.filter { $0.sendStatus == "read" }.count
                        fixture["statuses"] = matches.map(\.effectiveSendStatus)
                        fixture["ownReactions"] = matches.map { message in
                            message.reactions.filter { $0.key == "👍" && $0.isOwn }.count
                        }
                        fixture["pendingReactions"] = matches.map { message in
                            message.reactions.filter { $0.key == "👍" && $0.isPendingRemoval }.count
                        }
                        fixture["outbox"] = matches.map { chat.simulatorAcceptanceModel.reactionStateForAcceptance($0) }
                        fixture["reactions"] = matches.map { message in
                            message.reactions.filter { $0.key == "👍" && !$0.isPendingRemoval }
                                .reduce(0) { $0 + $1.count }
                        }
                        fixtures[slot] = fixture
                    }
                    value["closureFixtures"] = fixtures
                    value["closureReactionAttempts"] = closureReactionAttempts
                    value["closureReactionTransport"] = closureReactionTransport
                }
                if let marker = ProcessInfo.processInfo.environment["ZYNA_PRESENTATION_MARKER"] {
                    let messages = chat.simulatorAcceptanceModel.messages.filter {
                        $0.isOutgoing && $0.content.textPreview.hasPrefix(marker)
                    }
                    value["fixtureRemoteCount"] = messages.filter { $0.eventId != nil }.count
                }
                let ingestion = chat.simulatorAcceptanceModel.simulatorAcceptanceIngestion
                value["ingestion"] = ["rawItems": ingestion.rawItems, "rawBatches": ingestion.rawBatches,
                    "peakRawItems": ingestion.peakRawItems, "receivedItems": ingestion.receivedItems,
                    "mappedEvents": ingestion.mappedEvents, "peakMappedEvents": ingestion.peakMappedEvents,
                    "peakMappedBytes": ingestion.peakMappedBytes, "failedBatches": ingestion.failedBatches,
                    "completedBatches": ingestion.completedBatches]
                let scroll = chat.simulatorAcceptanceScroll
                scroll.accessibilityIdentifier = "acceptance.chat"
                if top === chat { value.merge(scrollState(scroll)) { _, new in new } }
            }
            if let profile = vc as? RoomProfileViewController {
                watch(profile, kind: "profile")
                if top === profile {
                    for (name, control) in profile.simulatorAcceptanceControls {
                        let target: UILabel
                        if let existing = controlTargets[name] { target = existing }
                        else {
                            target = UILabel()
                            target.isAccessibilityElement = true
                            target.isUserInteractionEnabled = false
                            target.accessibilityIdentifier = "acceptance.profile.\(name)"
                            target.accessibilityLabel = "Profile control coordinates: \(name)"
                            controlTargets[name] = target
                        }
                        if target.superview !== window { window.addSubview(target) }
                        target.frame = control.convert(control.bounds, to: window)
                        target.isHidden = control.isHidden || !target.frame.intersects(window.bounds)
                        if name.hasPrefix("tab."), control.accessibilityTraits.contains(.selected) {
                            value["selectedProfileTab"] = Int(name.dropFirst(4))
                        }
                    }
                }
                if let model = profile.simulatorAcceptanceModel {
                    watch(model, kind: "attachmentsModel")
                    watch(model.simulatorAcceptanceSource, kind: "attachmentsSource")
                    value["attachmentIndexErrors"] = model.diagnostics.indexErrors
                    value["attachmentBatches"] = model.diagnostics.batches
                    value["attachmentHitStart"] = model.diagnostics.hitStart
                }
                if let grid = profile.mediaGrid {
                    // A coordinate target for XCTest's native two-finger
                    // gesture. It cannot intercept touches. The layer-only
                    // grid is absent from Texture's AX tree with VoiceOver off.
                    if top === profile {
                        if gestureSurface.superview !== window { window.addSubview(gestureSurface) }
                        gestureSurface.frame = CGRect(x: 40, y: window.bounds.height - 360,
                            width: window.bounds.width - 80, height: 260)
                        gestureSurface.isHidden = false
                    }
                    watch(grid, kind: "mediaGrid"); watch(grid.catalog, kind: "mediaCatalog")
                    value["mediaCount"] = grid.catalog.count
                    value["mediaDepth"] = max(0, grid.normalizedOffset - grid.collapse)
                    value["mediaColumns"] = grid.columns
                    value["mediaTiles"] = grid.retainedTileCount
                    value["mediaCachedItems"] = grid.catalog.cachedItemCount
                    value["mediaObserving"] = grid.catalog.isObserving
                    if top === profile { value.merge(scrollState(grid.scrollView)) { _, new in new } }
                }
            }
        }
        watched = watched.filter { $0.value.object != nil }
        value["alive"] = Dictionary(grouping: watched.values, by: \.kind).mapValues(\.count)
        // Continue observing processing after the controller leaves navigation.
        // These temporary strong references last only for this synchronous sample.
        value["retainedModelQueues"] = watched.values.compactMap { entry -> [String: Int]? in
            guard let model = entry.object as? ChatViewModel else { return nil }
            let queue = model.simulatorAcceptanceIngestion
            return ["rawItems": queue.rawItems, "rawBatches": queue.rawBatches,
                "mappedEvents": queue.mappedEvents, "completedBatches": queue.completedBatches,
                "failedBatches": queue.failedBatches, "receivedItems": queue.receivedItems]
        }
        value["retainedIngestionQueues"] = watched.values.compactMap { entry -> [String: Int]? in
            // The final write owns metrics and its payload independently of
            // the batcher. Watch that lifetime too, without retaining it here.
            guard let metrics = entry.object as? TimelineIngestionMetrics else { return nil }
            let queue = metrics.snapshot
            return ["rawItems": queue.rawItems, "rawBatches": queue.rawBatches,
                "mappedEvents": queue.mappedEvents, "completedBatches": queue.completedBatches,
                "failedBatches": queue.failedBatches, "receivedItems": queue.receivedItems,
                "peakRawItems": queue.peakRawItems, "peakMappedEvents": queue.peakMappedEvents]
        }
        if label.superview !== window { label.removeFromSuperview(); window.addSubview(label) }
        label.frame = CGRect(x: 4, y: window.safeAreaInsets.top, width: window.bounds.width - 8, height: 9)
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8), let output else { return }
        label.text = text
        label.accessibilityLabel = text
        writer.async {
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: bytes + Data([10])) } catch { }
        }
    }

    private static func scrollState(_ scroll: UIScrollView) -> [String: Any] {
        ["offsetY": scroll.contentOffset.y, "contentHeight": scroll.contentSize.height,
         "viewportHeight": scroll.bounds.height, "insetTop": scroll.adjustedContentInset.top,
         "insetBottom": scroll.adjustedContentInset.bottom, "dragging": scroll.isDragging,
         "decelerating": scroll.isDecelerating]
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
#endif
