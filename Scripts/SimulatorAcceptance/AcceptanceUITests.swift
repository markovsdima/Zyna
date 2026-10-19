import XCTest

final class AcceptanceUITests: XCTestCase {
    private var roomLabel = ""
    private var expectedSDK = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        roomLabel = try requiredEnvironment("ZYNA_ACCEPTANCE_ROOM")
        expectedSDK = try requiredEnvironment("ZYNA_EXPECTED_SDK")
    }

    private func requiredEnvironment(_ key: String) throws -> String {
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Missing \(key)")
        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Missing \(key)")
        return value
    }

    private func fixtureMarker() throws -> String {
        let marker = try requiredEnvironment("ZYNA_FIXTURE_MARKER")
        XCTAssertNotNil(marker.range(of: #"^Zyna acceptance [A-Za-z0-9_-]{8,80}(?: [a-z][a-z0-9_-]{0,31})?$"#,
                                    options: .regularExpression), "Use a unique test-owned marker")
        return marker
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.app.zyna.Zyna")
        app.launchEnvironment = ["ZYNA_ACCEPTANCE": "1", "ZYNA_TIMELINE_INGEST_TRACE": "1"]
        if (ProcessInfo.processInfo.environment["ZYNA_PAIR_ACTION"] ?? "").hasPrefix("closure") {
            app.launchEnvironment["ZYNA_CLOSURE_MARKER"] = ProcessInfo.processInfo.environment["ZYNA_FIXTURE_MARKER"]
        }
        if ["deletionProbe", "photoPosition"].contains(ProcessInfo.processInfo.environment["ZYNA_PAIR_ACTION"] ?? "") {
            app.launchEnvironment["ZYNA_DELETE_TRACE"] = "1"
            app.launchEnvironment["ZYNA_PRESENTATION_MARKER"] = ProcessInfo.processInfo.environment["ZYNA_FIXTURE_MARKER"]
        }
        if ProcessInfo.processInfo.environment["ZYNA_PAIR_ACTION"] == "photoConversation" {
            app.launchEnvironment["ZYNA_PAIR_MARKER"] = ProcessInfo.processInfo.environment["ZYNA_FIXTURE_MARKER"]
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["acceptance.status"].waitForExistence(timeout: 60))
        XCTAssertEqual(status(app)["sdk"] as? String, expectedSDK,
            "The installed SDK must match the candidate before measuring or navigating")
        return app
    }

    private func status(_ app: XCUIApplication) -> [String: Any] {
        let text = app.staticTexts["acceptance.status"].label
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func photoPreviewSendButton(_ app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(identifier: "attachmentPreview.send")
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(matches.count, 1, "Select the preview button independently of the composer's Send label")
        let button = matches.element
        until(10) { button.isEnabled && button.isHittable }
        return button
    }

    private func mark(_ name: String, _ app: XCUIApplication) {
        print("[AcceptancePhase] \(name) epoch=\(Date().timeIntervalSince1970) status=\(app.staticTexts["acceptance.status"].label)")
    }

    private func wait(_ seconds: TimeInterval) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    private func waitUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { wait(1) }
        return predicate()
    }

    private func until(_ timeout: TimeInterval = 30, _ predicate: () -> Bool) {
        XCTAssertTrue(waitUntil(timeout, predicate))
    }

    private func openProfile(_ app: XCUIApplication) {
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
        until { self.status(app)["screen"] as? String == "ChatViewController" }
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20)); title.tap()
        until { self.status(app)["screen"] as? String == "RoomProfileViewController" }
        until(60) { (self.status(app)["mediaCount"] as? Int ?? 0) > 1000 }
    }

    func testLaunchMetrics() throws {
        let app = launch()
        until { self.status(app)["screen"] as? String == "RoomsViewController" }
        wait(15)
        mark("readiness", app)
        let sample = status(app)
        XCTAssertGreaterThan(sample["footprint"] as? Double ?? 0, 10_000_000)
        XCTAssertNotNil(sample["cpuPercent"] as? Double)
        XCTAssertNotNil(sample["thermalState"] as? Int)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "readiness"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func scrollToEdge(_ app: XCUIApplication, older: Bool, phase: String) {
        mark(phase + ".begin", app)
        for step in 0..<180 {
            let s = status(app)
            let y = s["offsetY"] as? Double ?? 0
            let height = s["contentHeight"] as? Double ?? 0
            let viewport = s["viewportHeight"] as? Double ?? 0
            let bottom = s["insetBottom"] as? Double ?? 0
            let reached = older ? y + viewport - bottom >= height - 8 : (s["mediaDepth"] as? Double ?? .infinity) <= 8
            if step > 0 && reached { mark(phase + ".edge", app); return }
            if older { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
            if step % 10 == 0 { mark(phase + ".step\(step)", app) }
        }
        XCTFail("Did not reach \(phase) edge within 180 gestures")
    }

    func testGestureProbe() throws {
        let app = launch()
        wait(15)
        openProfile(app)
        let media = app.staticTexts["acceptance.mediaGesture"]
        XCTAssertTrue(media.waitForExistence(timeout: 10))
        media.swipeUp(velocity: .fast)
        wait(2); mark("gesture.before", app)
        media.pinch(withScale: 0.5, velocity: -1)
        wait(3); mark("gesture.after", app)
        XCTAssertGreaterThan(status(app)["mediaColumns"] as? Int ?? 0, 3)
    }

    private func switchProfileTabs(_ app: XCUIApplication) {
        for index in [3, 1, 2, 0] {
            let tab = app.staticTexts["acceptance.profile.tab.\(index)"]
            XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
            until { self.status(app)["selectedProfileTab"] as? Int == index }
            wait(2)
        }
    }

    private func returnToList(_ app: XCUIApplication, phase: String) {
        app.staticTexts["acceptance.profile.back"].tap()
        until { self.status(app)["screen"] as? String == "ChatViewController" }
        mark(phase + ".chat", app)
        // The collection is inverted. Use physical screen coordinates so
        // XCTest does not derive swipe endpoints from its transformed AX frame.
        for _ in 0..<4 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        until { self.status(app)["screen"] as? String == "ChatViewController" }
        let away = status(app)
        XCTAssertGreaterThan(away["offsetY"] as? Double ?? 0,
            -(away["insetTop"] as? Double ?? 0) + 100)
        let latest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scroll to'")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        mark(phase + ".latestTap", app); latest.tap()
        until(15) {
            let s = self.status(app)
            return (s["offsetY"] as? Double ?? 999) <= -(s["insetTop"] as? Double ?? 0) + 8
        }
        mark(phase + ".latestReached", app)
        app.buttons["Back"].tap()
        until { self.status(app)["screen"] as? String == "RoomsViewController" }
        mark(phase + ".list", app)
    }

    func testControlsProbe() throws {
        let app = launch()
        openProfile(app)
        switchProfileTabs(app)
        returnToList(app, phase: "controls")
        wait(15); mark("controls.released", app)
    }

    /// Observe early exit separately from the full traversal. A timeout is a
    /// measurement result, not proof of a permanent retain cycle.
    func testBusyExitObservation() throws {
        let app = launch()
        openProfile(app)
        switchProfileTabs(app)
        let busy = waitUntil(60) {
            let queue = self.status(app)["ingestion"] as? [String: Int] ?? [:]
            return queue["rawItems", default: 0] >= 10_000
        }
        mark(busy ? "busy.confirmed" : "busy.notReproduced", app)
        returnToList(app, phase: "busy")
        wait(15); mark("busy.list15", app)
        wait(45); mark("busy.list60", app)
        let released = waitUntil(120) {
            let alive = self.status(app)["alive"] as? [String: Int] ?? [:]
            return alive["chatModel", default: 0] == 0 && alive["chatTimeline", default: 0] == 0 &&
                alive["ingestionBatcher", default: 0] == 0
        }
        mark(released ? "busy.released" : "busy.stillRetainedAt180", app)
    }

    /// One process throughout: terminating the app must not masquerade as
    /// draining accepted work or releasing a departed chat's objects.
    func testExitQueueLifecycle() throws {
        let app = launch()
        until { self.status(app)["screen"] as? String == "RoomsViewController" }
        wait(15); mark("exit.baseline", app)
        let kinds = ["chat", "chatModel", "chatTimeline", "ingestionBatcher", "ingestionMetrics",
            "profile", "mediaGrid", "mediaCatalog", "attachmentsModel", "attachmentsSource"]
        for cycle in 1...2 {
            let phase = "exit\(cycle)"
            mark(phase + ".open", app)
            openProfile(app)
            mark(phase + ".profile", app)
            if cycle == 2 {
                for step in 1...4 {
                    app.staticTexts["acceptance.profile.back"].tap()
                    until { self.status(app)["screen"] as? String == "ChatViewController" }
                    let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel)).firstMatch
                    XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
                    until { self.status(app)["screen"] as? String == "RoomProfileViewController" }
                    mark(phase + ".switch\(step)", app)
                }
            }
            app.staticTexts["acceptance.mediaGesture"].swipeUp(velocity: .fast)
            // Detect ordinary in-flight work, not an arbitrary huge backlog.
            // If sampling misses it, retain that limitation in the result.
            let busy = waitUntil(30) {
                let queues = self.status(app)["retainedIngestionQueues"] as? [[String: Int]] ?? []
                return queues.contains { $0["rawBatches", default: 0] > 0 || $0["mappedEvents", default: 0] > 0 }
            }
            mark(phase + (busy ? ".busy" : ".busyNotObserved"), app)
            app.staticTexts["acceptance.profile.back"].tap()
            until { self.status(app)["screen"] as? String == "ChatViewController" }
            mark(phase + ".beforeBack", app)
            app.buttons["Back"].tap()
            until { self.status(app)["screen"] as? String == "RoomsViewController" }
            mark(phase + ".list", app)

            // Preserve a full minute after exit even if work finishes early;
            // the independent probe samples once per second during this wait.
            wait(60); mark(phase + ".list60", app)
            let released = waitUntil(120) {
                let s = self.status(app)
                let alive = s["alive"] as? [String: Int] ?? [:]
                let queues = s["retainedIngestionQueues"] as? [[String: Int]] ?? []
                return kinds.allSatisfy { alive[$0, default: 0] == 0 } && queues.isEmpty
            }
            mark(phase + (released ? ".released" : ".retainedAt180"), app)
            XCTAssertTrue(released, "Departed chat/profile objects remain after 180 seconds")
            wait(10)
            let final = status(app)
            XCTAssertEqual(final["screen"] as? String, "RoomsViewController")
            let alive = final["alive"] as? [String: Int] ?? [:]
            XCTAssertTrue(kinds.allSatisfy { alive[$0, default: 0] == 0 })
            XCTAssertTrue((final["retainedIngestionQueues"] as? [[String: Int]] ?? []).isEmpty)
            mark(phase + ".stable", app)
        }
    }

    func testRepeatedAttachments() throws {
        let app = launch()
        until { self.status(app)["screen"] as? String == "RoomsViewController" }
        wait(20); mark("baseline", app)
        var findings: [String] = []
        for cycle in 1...2 {
            mark("cycle\(cycle).open", app)
            openProfile(app)
            mark("cycle\(cycle).profile", app)
            let media = app.staticTexts["acceptance.mediaGesture"]
            XCTAssertTrue(media.waitForExistence(timeout: 10))
            // First exercise the ordinary large tiles, then traverse the full
            // catalog at denser scales so the run stays short and repeatable.
            for _ in 0..<8 { app.swipeUp(velocity: .fast) }
            media.pinch(withScale: 0.65, velocity: -1)
            wait(2); mark("cycle\(cycle).dense", app)
            XCTAssertGreaterThan(status(app)["mediaColumns"] as? Int ?? 0, 3)
            scrollToEdge(app, older: true, phase: "cycle\(cycle).older")
            media.pinch(withScale: 0.65, velocity: -1)
            wait(2); mark("cycle\(cycle).zoomOut", app)
            scrollToEdge(app, older: false, phase: "cycle\(cycle).newer")
            media.pinch(withScale: 1.5, velocity: 1)
            media.pinch(withScale: 1.5, velocity: 1)
            wait(2); mark("cycle\(cycle).zoomIn", app)
            switchProfileTabs(app)
            mark("cycle\(cycle).settle", app)
            wait(45); mark("cycle\(cycle).settled", app)
            // Do not mistake cancellation on screen exit for a naturally
            // drained queue. A rebuild can enqueue a whole history snapshot.
            let drained = waitUntil(120) {
                let s = self.status(app)
                let queue = s["ingestion"] as? [String: Int] ?? [:]
                return s["attachmentHitStart"] as? Bool == true &&
                    queue["rawItems"] == 0 && queue["mappedEvents"] == 0
            }
            mark("cycle\(cycle)." + (drained ? "drained" : "drainTimeout"), app)
            if !drained { findings.append("cycle\(cycle): queue did not drain before exit") }
            let completed = status(app)
            if completed["attachmentIndexErrors"] as? Int != 0 { findings.append("cycle\(cycle): index errors") }
            if (completed["ingestion"] as? [String: Int])?["failedBatches"] != 0 { findings.append("cycle\(cycle): ingestion failures") }
            returnToList(app, phase: "cycle\(cycle)")
            wait(60); mark("cycle\(cycle).released", app)
            let alive = status(app)["alive"] as? [String: Int] ?? [:]
            for kind in ["chat", "chatModel", "chatTimeline", "profile", "mediaGrid", "mediaCatalog", "attachmentsModel", "attachmentsSource"] {
                if alive[kind, default: 0] > 0 { findings.append("cycle\(cycle): retained \(kind) after returning to room list") }
            }
        }
        XCTAssertTrue(findings.isEmpty, findings.joined(separator: "; "))
    }

    func testPairProbe() throws {
        let app = launch()
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
        until { self.status(app)["screen"] as? String == "ChatViewController" }
        wait(3)
        mark("pair.ready", app)
        print("[PairTree] \(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "pair-chat"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Open a real photo preview with text still in the composer. Never sends.
    func testPhotoPreviewSendSelector() throws {
        let photoLabel = try requiredEnvironment("ZYNA_PHOTO_LABEL")
        let app = launch()
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
        until(120) { (self.status(app)["chatRows"] as? Int ?? 0) > 0 && app.buttons["Attach"].isEnabled }
        let input = app.textViews["acceptance.messageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Send"].exists, "Preserve any existing draft")
        let caption = "Zyna acceptance " + UUID().uuidString + " preview selector"
        addTeardownBlock {
            let discard = app.buttons["attachmentPreview.discard"]
            if discard.exists {
                discard.tap()
            } else {
                let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Отменить"])).firstMatch
                if cancel.exists { cancel.tap() }
            }
            self.until(15) { !app.buttons["attachmentPreview.send"].exists && input.isHittable }
            // Composer drafts belong to this chat route. Close it to discard
            // the test-owned text, then verify a fresh route has an empty draft.
            app.buttons["Back"].tap()
            self.until { self.status(app)["screen"] as? String == "RoomsViewController" }
            XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
            self.until { self.status(app)["screen"] as? String == "ChatViewController" && input.exists }
            XCTAssertFalse(app.buttons["Send"].exists)
            XCTAssertNotEqual(input.value as? String, caption)
            self.mark("photo.preview.cleaned", app)
            app.buttons["Back"].tap()
            self.until { self.status(app)["screen"] as? String == "RoomsViewController" }
        }
        input.tap(); input.typeText(caption)
        XCTAssertEqual(input.value as? String, caption)
        XCTAssertTrue(app.buttons["Send"].exists)
        app.buttons["Attach"].tap()
        let photos = app.buttons.matching(NSPredicate(format: "label IN %@", ["Photos", "Фото"])).firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 10)); photos.tap()
        let asset = app.images.matching(NSPredicate(format:
            "identifier == 'PXGGridLayout-Info' AND label == %@", photoLabel)).firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 20))
        asset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Готово", "Done"])).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10)); XCTAssertTrue(done.isEnabled); done.tap()
        let send = photoPreviewSendButton(app)
        let legacy = app.buttons.matching(NSPredicate(format: "label IN %@", ["Отправить", "Send"]))
        print("[PhotoPreviewSelector] legacyMatches=\(legacy.count) legacyFirstIsPreview=\(legacy.firstMatch.identifier == send.identifier) previewHittable=\(send.isHittable)")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", caption)).firstMatch.exists)
        mark("photo.preview.selector", app)
    }

    func testPairAction() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let action = try XCTUnwrap(env["ZYNA_PAIR_ACTION"])
        if ["closureReactions", "closureOffline", "closureInspect", "closureCleanup"].contains(action) {
            try closureConversation(offline: action == "closureOffline")
            return
        }
        if action == "closureSettingsProbe" {
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.launch()
            wait(3)
            print("[ClosureSettings] \(settings.debugDescription)")
            return
        }
        if action == "cleanupProbe" {
            let marker = try fixtureMarker()
            let app = launch()
            let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
            XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap(); wait(10)
            let image = app.staticTexts.matching(NSPredicate(format:
                "identifier BEGINSWITH 'acceptance.image.' AND value == %@", marker + " photo")).firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 60))
            for _ in 0..<3 where image.frame.maxY > app.buttons["Attach"].frame.minY {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
                wait(2)
            }
            image.press(forDuration: 1)
            let delete = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Delete'")).firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 10)); delete.tap()
            until(60) { !image.exists }; wait(10); XCTAssertFalse(image.exists)
            return
        }
        if action == "deletionProbe" || action == "photoPosition" {
            try presentationProbe(photo: action == "photoPosition")
            return
        }
        if action == "conversation" {
            try pairConversation()
            return
        }
        if action == "photoConversation" {
            try pairPhotoConversation()
            return
        }
        if action == "photoPickerProbe" {
            let app = launch()
            let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
            XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
            until(120) { (self.status(app)["chatRows"] as? Int ?? 0) > 0 && app.buttons["Attach"].isEnabled }
            wait(3)
            print("[PairChatBeforePicker] \(app.debugDescription)")
            XCTAssertTrue(app.buttons["Attach"].waitForExistence(timeout: 30))
            app.buttons["Attach"].tap()
            let photos = app.buttons.matching(NSPredicate(format: "label == 'Photos' OR label == 'Фото'")).firstMatch
            if !photos.waitForExistence(timeout: 2) {
                app.buttons["Attach"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(photos.waitForExistence(timeout: 10)); photos.tap()
            wait(5)
            print("[PairTree] \(app.debugDescription)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "photo-picker"; attachment.lifetime = .keepAlways; add(attachment)
            return
        }
        let value = env["ZYNA_PAIR_VALUE"] ?? ""
        let target = env["ZYNA_PAIR_TARGET"] ?? ""
        let marker = ["sendText", "menu", "observe"].contains(action) ? try fixtureMarker() : ""
        let app = XCUIApplication(bundleIdentifier: "com.app.zyna.Zyna")
        print("[PairState] before=\(app.state.rawValue) action=\(action)")
        XCTAssertNotEqual(app.state, .notRunning, "Prepare the client first; do not silently reopen the receiver")
        app.activate()
        XCTAssertTrue(app.staticTexts["acceptance.status"].waitForExistence(timeout: 30))
        XCTAssertEqual(status(app)["sdk"] as? String, env["ZYNA_EXPECTED_SDK"])
        func matches(_ text: String) -> XCUIElementQuery {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
        }
        func item(_ text: String) -> XCUIElement {
            let query = matches(text)
            XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 60), "Missing \(text)")
            return query.firstMatch
        }
        switch action {
        case "inspect":
            until(120) { (self.status(app)["chatRows"] as? Int ?? 0) > 0 }
        case "input":
            app.textViews["acceptance.messageInput"].tap()
        case "sendText":
            XCTAssertTrue(value.hasPrefix(marker + " "))
            XCTAssertFalse(app.buttons["Send"].exists, "Preserve an existing draft")
            app.textViews["acceptance.messageInput"].tap()
            app.typeText(value)
            app.buttons["Send"].tap()
            _ = item(value)
        case "menu":
            XCTAssertTrue(target.hasPrefix(marker + " "))
            item(target).press(forDuration: 1)
            wait(1)
        case "observe":
            XCTAssertTrue(value.hasPrefix(marker + " "))
            _ = item(value)
            wait(3)
            print("[PairMatches] \(value): \(matches(value).count)")
        case "profile":
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel)).firstMatch.tap()
            until { self.status(app)["screen"] as? String == "RoomProfileViewController" }
        case "back":
            app.staticTexts["acceptance.profile.back"].tap()
            until { self.status(app)["screen"] as? String == "ChatViewController" }
        default:
            XCTFail("Unsupported pair action: \(action)")
        }
        mark("pair." + action, app)
        print("[PairTree] \(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "pair-" + action; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Test-owned messages only. Uses ordinary UI and the real network, not transport mocks.
    private func closureConversation(offline: Bool) throws {
        #if !targetEnvironment(simulator)
        if offline {
            XCTAssertEqual(ProcessInfo.processInfo.environment["ZYNA_OFFLINE_WIRED_VERIFIED"], "1",
                "Launch offline testing through pair.py after its USB check")
        }
        #endif
        let marker = try fixtureMarker()
        let app = launch()
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
        until(120) { (self.status(app)["chatRows"] as? Int ?? 0) > 0 && app.buttons["Attach"].isEnabled }
        func latest() {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scroll to '")).firstMatch
            if button.exists { button.tap(); wait(2) }
        }
        latest()
        func text(_ slot: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker + " " + slot)).firstMatch
        }
        func fixture(_ slot: String) -> [String: Any] {
            (status(app)["closureFixtures"] as? [String: [String: Any]])?[slot] ?? [:]
        }
        func count(_ slot: String) -> Int { fixture(slot)["count"] as? Int ?? 0 }
        func received(_ slot: String, timeout: TimeInterval = 180) {
            until(timeout) { fixture(slot)["remote"] as? Int == 1 }
            latest()
            XCTAssertTrue(text(slot).waitForExistence(timeout: 20))
            XCTAssertEqual(count(slot), 1)
        }
        func send(_ slot: String) {
            XCTAssertFalse(app.buttons["Send"].exists, "Do not alter an existing draft")
            XCTAssertEqual(count(slot), 0, "Use a fresh fixture marker")
            let input = app.textViews["acceptance.messageInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap()
            input.typeText(marker + " " + slot)
            app.buttons["Send"].tap()
            until { count(slot) == 1 }
        }
        func menu(_ slot: String) {
            if !text(slot).exists { latest() }
            XCTAssertTrue(text(slot).waitForExistence(timeout: 20))
            // AX includes rows covered by the composer. Reveal the whole row
            // using an ordinary scroll before choosing a long-press location.
            for _ in 0..<3 where text(slot).frame.maxY > app.buttons["Attach"].frame.minY - 8 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
                wait(1)
            }
            XCTAssertLessThan(text(slot).frame.maxY, app.buttons["Attach"].frame.minY)
            // A row's AX frame includes the reaction pill and full-width empty
            // space. Hold its text body, not the centre of the entire row.
            let outgoing = fixture(slot)["outgoing"] as? Int == 1
            for _ in 0..<2 {
                text(slot).coordinate(withNormalizedOffset: CGVector(dx: outgoing ? 0.65 : 0.35, dy: 0.3))
                    .press(forDuration: 2)
                if waitUntil(3, { action("Copy").exists || action("👍").exists || action("Delete").exists }) {
                    return
                }
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "closure-menu-failure"; screenshot.lifetime = .keepAlways; add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "closure-menu-failure-tree"; tree.lifetime = .keepAlways; add(tree)
            XCTFail("Could not open the message menu for \(slot); no reaction tap was attempted")
        }
        func action(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
        }
        func delete(_ slot: String) {
            menu(slot)
            XCTAssertTrue(action("Delete").waitForExistence(timeout: 10)); action("Delete").tap()
            until(60) { count(slot) == 0 }
        }
        func stable(_ seconds: Int, slots: [String], reactionCounts: [String: Int] = [:]) {
            for _ in 0..<seconds / 2 {
                for slot in slots {
                    XCTAssertEqual(count(slot), 1)
                    if let expected = reactionCounts[slot] {
                        XCTAssertEqual(fixture(slot)["reactions"] as? [Int], [expected])
                    }
                }
                wait(2)
            }
        }
        let selectedAction = ProcessInfo.processInfo.environment["ZYNA_PAIR_ACTION"]
        if selectedAction == "closureCleanup" {
            for slot in ["even", "odd", "done", "offline", "received"] {
                if fixture(slot)["outgoing"] as? Int == 1 { delete(slot) }
            }
            until(90) { ["even", "odd", "done", "offline", "received"].allSatisfy { count($0) == 0 } }
            wait(10); mark("closure.cleanup.complete", app)
            return
        }
        if selectedAction == "closureInspect" {
            received("even"); mark("closure.inspect.before", app)
            for step in 0..<2 {
                menu("even")
                XCTAssertTrue(action("👍").waitForExistence(timeout: 10)); action("👍").tap()
                wait(8); mark("closure.inspect.after\(step)", app)
            }
            return
        }
        mark(offline ? "closure.offline.ready" : "closure.reactions.ready", app)
        var closureFindings: [String] = []
        func reactionStateIsCorrect() -> Bool {
            fixture("even")["reactions"] as? [Int] == [0] && fixture("odd")["reactions"] as? [Int] == [1]
        }
        if !offline {
            #if targetEnvironment(simulator)
            received("even"); received("odd")
            let resume = (ProcessInfo.processInfo.environment["ZYNA_PAIR_TARGET"] ?? "").split(separator: ":")
            var completed = ["odd": 0, "even": 0]
            if resume.count == 3, resume[0] == "resume" {
                completed["odd"] = try XCTUnwrap(Int(resume[1]))
                completed["even"] = try XCTUnwrap(Int(resume[2]))
                XCTAssertTrue((0...7).contains(completed["odd"]!))
                XCTAssertTrue((0...6).contains(completed["even"]!))
                until(20) {
                    ["odd", "even"].allSatisfy { fixture($0)["reactions"] as? [Int] == [completed[$0]! % 2] }
                }
                mark("closure.resume.confirmed", app)
            }
            // No peer acknowledgement or remote-state wait between toggles.
            // XCTest gesture/menu overhead is retained in the recorded timings.
            for (slot, toggles) in [("odd", 7), ("even", 6)] {
                mark("closure.toggle.\(slot).begin", app)
                for index in completed[slot]!..<toggles {
                    menu(slot)
                    XCTAssertTrue(action("👍").waitForExistence(timeout: 10)); action("👍").tap()
                    print("[ClosureToggle] slot=\(slot) index=\(index) epoch=\(Date().timeIntervalSince1970)")
                }
                mark("closure.toggle.\(slot).end", app)
            }
            if !waitUntil(20, reactionStateIsCorrect) { closureFindings.append("reaction parity did not settle") }
            send("done"); received("done")
            wait(20)
            if !reactionStateIsCorrect() { closureFindings.append("reaction parity differs after observation") }
            until(180) { count("even") == 0 && count("odd") == 0 }
            delete("done")
            #else
            if (ProcessInfo.processInfo.environment["ZYNA_PAIR_TARGET"] ?? "").hasPrefix("resume") {
                received("even"); received("odd")
            } else {
                send("even"); received("even"); send("odd"); received("odd")
            }
            // Profile loading runs alongside the peer's reads and reaction changes.
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel)).firstMatch.tap()
            until { self.status(app)["screen"] as? String == "RoomProfileViewController" }
            wait(35); mark("closure.receipts.profile", app)
            app.staticTexts["acceptance.profile.back"].tap()
            until { self.status(app)["screen"] as? String == "ChatViewController" }
            received("done")
            if !waitUntil(20, reactionStateIsCorrect) { closureFindings.append("peer reaction parity did not settle") }
            let read = waitUntil(30) { fixture("even")["read"] as? Int == 1 && fixture("odd")["read"] as? Int == 1 }
            if !read { closureFindings.append("read receipts did not settle") }
            mark(read ? "closure.receipts.confirmed" : "closure.receipts.missing", app)
            wait(20)
            if !reactionStateIsCorrect() { closureFindings.append("peer reaction parity differs after observation") }
            delete("even"); delete("odd")
            until(180) { count("done") == 0 }
            #endif
        } else {
            #if targetEnvironment(simulator)
            // Remain online as the independent witness of reconnection/duplication.
            until(420) { count("received") == 1 || count("done") == 1 }
            if count("received") == 1 {
                received("offline"); stable(20, slots: ["offline", "received"])
                until(180) { count("offline") == 0 && count("received") == 0 }
            } else {
                for _ in 0..<10 { XCTAssertEqual(count("offline"), 0); wait(2) }
                until(180) { count("done") == 0 }
            }
            #else
            // Always restore the exact initial network switch values, also on failure.
            let network = SettingsNetwork(self)
            addTeardownBlock { network.restore(); app.activate() }
            try network.captureAndDisconnect()
            app.activate(); wait(5)
            send("offline")
            wait(30); mark("closure.offline.pending", app)
            XCTAssertEqual(fixture("offline")["remote"] as? Int, 0)
            menu("offline")
            let removeFailed = action("Remove Failed Send"), removeLocal = action("Remove Local Send")
            let cancelled = removeFailed.exists || removeLocal.exists
            if cancelled {
                (removeFailed.exists ? removeFailed : removeLocal).tap()
                until { count("offline") == 0 }
                mark("closure.offline.cancelled", app)
            } else {
                print("[ClosureOffline] cancellation=not_available statuses=\(fixture("offline")["statuses"] ?? [])")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.2)).tap()
            }
            network.restore(); app.activate(); wait(5)
            if cancelled {
                send("done"); received("done"); wait(30)
                XCTAssertEqual(count("offline"), 0); delete("done")
            } else {
                if !waitUntil(180, { fixture("offline")["remote"] as? Int == 1 }) {
                    menu("offline")
                    XCTAssertTrue(action("Retry Send").waitForExistence(timeout: 10))
                    action("Retry Send").tap(); mark("closure.offline.manualRetry", app)
                } else { mark("closure.offline.automaticResume", app) }
                received("offline"); send("received"); received("received")
                until(120) { fixture("offline")["read"] as? Int == 1 }
                stable(30, slots: ["offline", "received"])
                delete("offline"); delete("received")
            }
            #endif
        }
        wait(10); mark(offline ? "closure.offline.complete" : "closure.reactions.complete", app)
        for slot in ["even", "odd", "done", "offline", "received"] { XCTAssertEqual(count(slot), 0) }
        XCTAssertTrue(closureFindings.isEmpty, closureFindings.joined(separator: "; "))
    }

    private final class SettingsNetwork {
        private let test: AcceptanceUITests
        private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        private var original: (airplane: String, wifi: String)?
        private var restored = false
        init(_ test: AcceptanceUITests) { self.test = test }
        private var airplane: XCUIElement {
            settings.switches.matching(NSPredicate(format:
                "label == 'Airplane Mode' OR label == 'Авиарежим'")).firstMatch
        }
        private func root() -> Bool {
            settings.activate()
            for _ in 0..<8 {
                if airplane.waitForExistence(timeout: 2) { return true }
                let back = settings.navigationBars.buttons.firstMatch
                guard back.exists else { return false }
                back.tap()
            }
            return airplane.exists
        }
        private func wifi() -> XCUIElement? {
            guard root() else { return nil }
            let row = settings.buttons["com.apple.settings.wifi"]
            let fallback = settings.staticTexts.matching(NSPredicate(format: "label == 'Wi-Fi' OR label == 'Wi‑Fi'")).firstMatch
            if row.exists { row.tap() }
            else if fallback.exists { fallback.tap() }
            else { return nil }
            let control = settings.switches.matching(NSPredicate(format:
                "(label CONTAINS 'Wi' AND label CONTAINS 'Fi') OR identifier == 'Wi-Fi'")).firstMatch
            return control.waitForExistence(timeout: 10) ? control : nil
        }
        private func set(_ control: XCUIElement, to value: String) -> Bool {
            if control.value as? String == value { return true }
            // Settings exposes the entire row as a switch. Its centre can be
            // the label rather than the actual toggle on the trailing edge.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let predicate = NSPredicate(format: "value == %@", value)
            return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: control)],
                                 timeout: 5) == .completed
        }
        func captureAndDisconnect() throws {
            settings.launch()
            guard root(), let airValue = airplane.value as? String, ["0", "1"].contains(airValue) else {
                XCTFail("Cannot identify Airplane Mode; no network settings changed")
                return
            }
            let wifiSwitch = try XCTUnwrap(wifi(), "Cannot identify Wi-Fi; no network settings changed")
            let wifiValue = try XCTUnwrap(wifiSwitch.value as? String)
            XCTAssertTrue(["0", "1"].contains(wifiValue))
            original = (airValue, wifiValue)
            // Persist the intended restoration before changing either switch.
            let captured = "[ClosureNetwork] captured airplane=\(airValue) wifi=\(wifiValue)"
            print(captured)
            let attachment = XCTAttachment(string: captured)
            attachment.name = "network-before"; attachment.lifetime = .keepAlways; test.add(attachment)
            XCTAssertTrue(root())
            XCTAssertTrue(set(airplane, to: "1"), "Airplane Mode must become enabled")
            let currentWifi = try XCTUnwrap(wifi())
            XCTAssertTrue(set(currentWifi, to: "0"), "Wi-Fi must become disabled")
            print("[ClosureNetwork] disconnected airplane=1 wifi=0 originalAirplane=\(airValue) originalWifi=\(wifiValue)")
            test.wait(3)
        }
        func restore() {
            guard let original, !restored else { return }
            guard root() else { XCTFail("Restore network manually: cannot open Settings root"); return }
            let airOK = set(airplane, to: original.airplane)
            guard let currentWifi = wifi() else { XCTFail("Restore Wi-Fi manually: switch unavailable"); return }
            let wifiOK = set(currentWifi, to: original.wifi)
            restored = airOK && wifiOK
            XCTAssertTrue(restored, "Initial network settings must be restored")
            print("[ClosureNetwork] restored=\(restored) airplane=\(original.airplane) wifi=\(original.wifi)")
        }
    }

    private func presentationProbe(photo: Bool) throws {
        let marker = try fixtureMarker()
        let app = launch()
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
        until(120) { (self.status(app)["chatRows"] as? Int ?? 0) > 0 && app.buttons["Attach"].isEnabled }
        func latest() {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scroll to '")).firstMatch
            if button.exists { button.tap(); wait(3) }
        }
        latest()
        func editor() -> XCUIElement {
            let field = app.textViews["acceptance.messageInput"]
            XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            return field
        }
        func text(_ body: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        }
        func menu(_ element: XCUIElement, _ action: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 30)); element.press(forDuration: 1)
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", action)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
        }
        var failures: [String] = []
        func remove(_ element: XCUIElement, round: Int) {
            menu(element, "Delete")
            var disappeared = false, reappeared = false
            for _ in 0..<20 {
                wait(1)
                if element.exists { if disappeared { reappeared = true } }
                else { disappeared = true }
            }
            print("[PairDeletion] round=\(round) disappeared=\(disappeared) reappeared=\(reappeared) present=\(element.exists)")
            mark("delete.observed.\(round)", app)
            if !disappeared || reappeared || element.exists { failures.append("Deletion \(round) did not remain absent") }
        }
        mark("presentation.ready", app)
        if photo {
            let caption = marker + " photo"
            XCTAssertFalse(app.buttons["Send"].exists, "Preserve any existing draft")
            let field = editor(); field.typeText(caption)
            XCTAssertEqual(field.value as? String, caption)
            app.buttons["Attach"].tap()
            let photos = app.buttons.matching(NSPredicate(format: "label == 'Photos' OR label == 'Фото'")).firstMatch
            if !photos.waitForExistence(timeout: 2) {
                app.buttons["Attach"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(photos.waitForExistence(timeout: 10)); photos.tap()
            let asset = app.images.matching(NSPredicate(format:
                "identifier == 'PXGGridLayout-Info' AND label == %@", try requiredEnvironment("ZYNA_PHOTO_LABEL"))).firstMatch
            XCTAssertTrue(asset.waitForExistence(timeout: 20))
            asset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Готово", "Done"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 10)); XCTAssertTrue(done.isEnabled); done.tap()
            let send = photoPreviewSendButton(app)
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", caption)).firstMatch.exists)
            // Wait for the preview and keyboard to finish changing the button frame.
            wait(3)
            send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            until(10) { self.status(app)["screen"] as? String == "ChatViewController" }
            // Observe before any corrective scroll. A later latest() is cleanup only.
            wait(12)
            mark("photo.position", app)
            let state = status(app)
            let distance = (state["offsetY"] as? Double ?? 1_000) + (state["insetTop"] as? Double ?? 0)
            if abs(distance) > 3 { failures.append("Photo remained \(distance) points from live") }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "photo-position"; shot.lifetime = .keepAlways; add(shot)
            latest()
            let image = app.staticTexts.matching(NSPredicate(format:
                "identifier BEGINSWITH 'acceptance.image.' AND value == %@", caption)).firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 60))
            let id = image.identifier
            remove(app.staticTexts[id], round: 0)
        } else {
            for round in 0..<3 {
                var body = marker + " text \(round) edit 0"
                if !text(body).exists {
                    XCTAssertFalse(app.buttons["Send"].exists, "Preserve any existing draft")
                    let field = editor(); field.typeText(body)
                    XCTAssertEqual(field.value as? String, body)
                    app.buttons["Send"].tap()
                }
                XCTAssertTrue(text(body).waitForExistence(timeout: 60)); wait(4)
                until(180) { (self.status(app)["fixtureRemoteCount"] as? Int ?? 0) > 0 }
                for edit in 0..<(round == 1 ? 5 : round == 2 ? 1 : 0) {
                    menu(text(body), "Edit")
                    let field = editor(); XCTAssertEqual(field.value as? String, body)
                    let suffix = " x\(edit + 1)"
                    body += suffix
                    field.typeText(suffix)
                    XCTAssertEqual(field.value as? String, body); app.buttons["Send"].tap()
                    XCTAssertTrue(text(body).waitForExistence(timeout: 60)); wait(2)
                }
                remove(text(body), round: round)
            }
        }
        mark("presentation.complete", app)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    private func pairConversation() throws {
        let app = launch()
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
        until(120) { (self.status(app)["chatRows"] as? Int ?? 0) > 0 && app.buttons["Attach"].isEnabled }
        let marker = try fixtureMarker()
        func query(_ body: String) -> XCUIElementQuery {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body))
        }
        func received(_ body: String) {
            XCTAssertTrue(query(body).firstMatch.waitForExistence(timeout: 120), body)
            wait(2)
            XCTAssertEqual(query(body).count, 1, "Expected one rendered message: \(body)")
            mark("pair.received." + body.replacingOccurrences(of: " ", with: "_"), app)
        }
        func send(_ body: String) {
            XCTAssertTrue(body.hasPrefix(marker))
            XCTAssertFalse(app.buttons["Send"].exists, "Do not append to an existing draft")
            let editor = app.textViews["acceptance.messageInput"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            editor.tap()
            editor.typeText(body)
            XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 10))
            app.buttons["Send"].tap()
            received(body)
        }
        func menu(_ body: String, _ action: String) {
            XCTAssertTrue(body.hasPrefix(marker))
            received(body)
            query(body).firstMatch.press(forDuration: 1)
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", action)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), action)
            item.tap()
        }
        func edit(_ old: String, _ new: String) {
            menu(old, "Edit")
            let editor = app.textViews["acceptance.messageInput"]
            XCTAssertEqual(editor.value as? String, old)
            editor.tap()
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            // XCTest can type with an attached hardware keyboard as well.
            // Do not require a software keyboard accessibility element.
            editor.typeKey("a", modifierFlags: .command)
            editor.typeText(new)
            XCTAssertEqual(editor.value as? String, new)
            app.buttons["Send"].tap()
            received(new)
            XCTAssertFalse(query(old).firstMatch.exists)
        }
        func absent(_ body: String) {
            until(120) { !query(body).firstMatch.exists }
            wait(3)
            XCTAssertFalse(query(body).firstMatch.exists)
            mark("pair.absent." + body.replacingOccurrences(of: " ", with: "_"), app)
        }
        func reaction(_ body: String, present: Bool) {
            until(120) {
                let label = query(body).firstMatch.label.lowercased()
                let hasReaction = label.contains("reaction") || label.contains("реакц")
                return hasReaction == present
            }
            received(body)
            print("[PairReaction] present=\(present) label=\(query(body).firstMatch.label)")
        }
        let text0 = marker + " text 0", text1 = marker + " text 1", text2 = marker + " text 2"
        func ack(_ n: Int) -> String { marker + " ack \(n)" }
        mark("pair.conversation.ready", app)
        #if targetEnvironment(simulator)
        received(text0)
        if !query(ack(0)).firstMatch.exists { send(ack(0)) }
        received(text1); edit(ack(0), ack(1))
        received(text2); edit(ack(1), ack(2))
        reaction(ack(2), present: true); edit(ack(2), ack(3))
        reaction(ack(3), present: false); edit(ack(3), ack(4))
        absent(text2); edit(ack(4), ack(5))
        wait(8)
        menu(ack(5), "Delete"); absent(ack(5))
        #else
        if !query(text0).firstMatch.exists { send(text0) }
        received(ack(0))
        edit(text0, text1); received(ack(1))
        edit(text1, text2); received(ack(2))
        menu(ack(2), "👍"); received(ack(3))
        menu(ack(3), "👍"); received(ack(4))
        menu(text2, "Delete"); absent(text2)
        received(ack(5)); absent(ack(5))
        #endif
        mark("pair.conversation.complete", app)
        print("[PairTree] \(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "pair-conversation-complete"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func pairPhotoConversation() throws {
        let app = launch()
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30)); room.tap()
        until(120) { (self.status(app)["chatRows"] as? Int ?? 0) > 0 && app.buttons["Attach"].isEnabled }
        wait(3)
        let marker = try fixtureMarker()
        let caption0 = marker + " photo 0", caption1 = marker + " photo 1"
        func latest() {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Scroll to '")).firstMatch
            if button.exists {
                mark("photo.latest.begin", app); button.tap(); wait(3)
                mark("photo.latest.end", app)
            }
        }
        latest()
        func ack(_ n: Int) -> String { marker + " photo ack \(n)" }
        func text(_ body: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        }
        func received(_ body: String) {
            latest()
            XCTAssertTrue(text(body).waitForExistence(timeout: 240), body)
            wait(2)
            mark("photo.received." + body.replacingOccurrences(of: " ", with: "_"), app)
        }
        func menu(_ element: XCUIElement, _ action: String) {
            XCTAssertTrue(element.exists)
            element.press(forDuration: 1)
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", action)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), action); item.tap()
        }
        func editor() -> XCUIElement {
            let field = app.textViews["acceptance.messageInput"]
            XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            return field
        }
        func send(_ body: String) {
            XCTAssertTrue(body.hasPrefix(marker))
            XCTAssertFalse(app.buttons["Send"].exists, "Do not overwrite a draft")
            let field = editor(); field.typeText(body)
            XCTAssertEqual(field.value as? String, body)
            app.buttons["Send"].tap(); received(body)
        }
        func editAck(_ from: Int, _ to: Int) {
            received(ack(from)); menu(text(ack(from)), "Edit")
            let field = editor()
            XCTAssertEqual(field.value as? String, ack(from))
            field.typeKey("a", modifierFlags: .command); field.typeText(ack(to))
            XCTAssertEqual(field.value as? String, ack(to))
            app.buttons["Send"].tap(); received(ack(to))
        }
        func image(_ caption: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format:
                "identifier BEGINSWITH 'acceptance.image.' AND value == %@", caption)).firstMatch
        }
        func captionReceived(_ caption: String) -> String {
            XCTAssertTrue(image(caption).waitForExistence(timeout: 240), caption)
            wait(2)
            let id = image(caption).identifier
            XCTAssertTrue(id.hasPrefix("acceptance.image."))
            mark(caption == caption0 ? "photo.caption0" : "photo.caption1", app)
            return id
        }
        func changeCaption(_ id: String, old: String, new: String) {
            menu(app.staticTexts[id], "Edit photo caption (test)")
            let field = app.textFields["debug.photoCaption"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            XCTAssertEqual(field.value as? String, old)
            field.tap()
            let clear = field.buttons.firstMatch
            XCTAssertTrue(clear.waitForExistence(timeout: 10))
            clear.tap()
            if !new.isEmpty { field.typeText(new) }
            let actual = field.value as? String ?? ""
            XCTAssertTrue(actual == new || (new.isEmpty && actual == "Caption"), "Unexpected caption: \(actual)")
            app.alerts.buttons["Save"].tap()
        }
        func profile() {
            let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel)).firstMatch
            title.tap()
            until(30) { self.status(app)["screen"] as? String == "RoomProfileViewController" }
            if self.status(app)["selectedProfileTab"] as? Int != 0 {
                app.staticTexts["acceptance.profile.tab.0"].tap()
            }
            until(60) { (self.status(app)["mediaCount"] as? Int ?? 0) > 1000 }
            mark("photo.profile", app)
        }
        func back() {
            app.staticTexts["acceptance.profile.back"].tap()
            until { self.status(app)["screen"] as? String == "ChatViewController" }
        }
        func absent(_ element: XCUIElement, phase: String) {
            // Record reappearances rather than confusing a transient animation
            // disappearance with settled deletion.
            var absentSince: Date?, reappeared = false
            let settled = waitUntil(120) {
                if element.exists {
                    if absentSince != nil { reappeared = true }
                    absentSince = nil
                    return false
                }
                if absentSince == nil { absentSince = Date() }
                return Date().timeIntervalSince(absentSince!) >= 5
            }
            print("[PairDeletion] phase=\(phase) settled=\(settled) reappeared=\(reappeared)")
            XCTAssertTrue(settled, phase)
            mark(phase, app)
            // Keep gathering the other client's result if a transient occurred.
        }
        XCTAssertFalse(text(marker + " text").exists)
        XCTAssertFalse(text(marker + " ack").exists)
        mark("photo.ready", app)
        #if targetEnvironment(simulator)
        if !image(caption0).exists {
            XCTAssertFalse(app.buttons["Send"].exists)
            let field = editor(); field.typeText(caption0)
            XCTAssertEqual(field.value as? String, caption0)
            app.buttons["Attach"].tap()
            let photos = app.buttons.matching(NSPredicate(format: "label == 'Photos' OR label == 'Фото'")).firstMatch
            if !photos.waitForExistence(timeout: 2) {
                app.buttons["Attach"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            XCTAssertTrue(photos.waitForExistence(timeout: 10)); photos.tap()
            // This exact asset was imported and visually verified in the picker probe.
            let asset = app.images.matching(NSPredicate(format:
                "identifier == 'PXGGridLayout-Info' AND label == %@", try requiredEnvironment("ZYNA_PHOTO_LABEL"))).firstMatch
            XCTAssertTrue(asset.waitForExistence(timeout: 20))
            // Photos exposes a layer-backed grid image with no XCTest hit point.
            asset.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Готово", "Done"])).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 10)); XCTAssertTrue(done.isEnabled); done.tap()
            let sendPhoto = photoPreviewSendButton(app)
            print("[PairPhotoPreview] \(app.debugDescription)")
            let preview = XCTAttachment(screenshot: app.screenshot())
            preview.name = "service-photo-preview"; preview.lifetime = .keepAlways; add(preview)
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@", caption0)).firstMatch.exists)
            sendPhoto.tap()
        }
        latest()
        _ = captionReceived(caption0); received(ack(0))
        let id = image(caption0).identifier
        changeCaption(id, old: caption0, new: caption1)
        _ = captionReceived(caption1); received(ack(1)); wait(5)
        changeCaption(id, old: caption1, new: "")
        until(120) { app.staticTexts[id].exists && (app.staticTexts[id].value as? String ?? "") == "" }
        mark("photo.cleared.sender", app)
        received(ack(2)); wait(5)
        menu(app.staticTexts[id], "Delete")
        absent(app.staticTexts[id], phase: "photo.deleted.sender")
        received(ack(3)); menu(text(ack(3)), "👍")
        absent(text(ack(3)), phase: "photo.ack.deleted.receiver")
        #else
        let id = captionReceived(caption0)
        if !text(ack(0)).exists { send(ack(0)) }
        XCTAssertEqual(captionReceived(caption1), id)
        editAck(0, 1); profile()
        until(180) { self.status(app)["pairedImageState"] as? String == "empty" }
        XCTAssertEqual(self.status(app)["screen"] as? String, "RoomProfileViewController")
        mark("photo.cleared.behindProfile", app)
        back()
        XCTAssertTrue(app.staticTexts[id].exists)
        XCTAssertEqual(app.staticTexts[id].value as? String ?? "", "")
        editAck(1, 2); profile()
        let count = try XCTUnwrap(self.status(app)["mediaCount"] as? Int)
        until(180) { self.status(app)["mediaCount"] as? Int == count - 1 }
        mark("photo.deleted.grid", app)
        back(); absent(app.staticTexts[id], phase: "photo.deleted.chatAfterProfile")
        editAck(2, 3)
        until(120) {
            let label = text(ack(3)).label.lowercased()
            return label.contains("reaction") || label.contains("реакц")
        }
        menu(text(ack(3)), "Delete")
        absent(text(ack(3)), phase: "photo.ack.deleted.sender")
        #endif
        mark("photo.complete", app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "photo-complete"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testNavigationProbe() throws {
        let app = launch()
        let room = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel + ",")).firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 30))
        room.tap()
        XCTAssertTrue(app.collectionViews["acceptance.chat"].waitForExistence(timeout: 30))
        mark("chat", app)
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", roomLabel)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        until { self.status(app)["screen"] as? String == "RoomProfileViewController" }
        wait(5)
        mark("profile", app)
        print("[ProfileTree] \(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "profile"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons.matching(NSPredicate(format: "label == 'Back' OR label == 'Назад'")).firstMatch.tap()
        wait(2)
        mark("back-chat", app)
        app.buttons["Back"].tap()
        wait(10)
        mark("back-list", app)
    }

    func testProbe() throws {
        let app = launch()
        print("[AcceptanceTree] \(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "initial-screen"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
