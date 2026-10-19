// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import MatrixRustSDK
import Testing
import UIKit
@testable import Zyna

private func linkedRoom(membership: Membership? = nil, rule: JoinRule? = .public,
                        allowed: Bool = false) -> MatrixLinkedRoom {
    MatrixLinkedRoom(info: RoomPreviewInfo(roomId: "!linked:example.org",
        canonicalAlias: "#linked:example.org", name: "Linked room", topic: "Description",
        avatarUrl: nil, numJoinedMembers: 4, numActiveMembers: nil, roomType: .room,
        isHistoryWorldReadable: nil, membership: membership, joinRule: rule,
        isDirect: nil, heroes: nil), via: ["relay.example.org"], canJoinRestricted: allowed, room: nil)
}

private final class MatrixLinkTestSource: MatrixRoomLinkSource, @unchecked Sendable {
    let value = Atomic(linkedRoom())
    let reads = Atomic(0)
    let links = Atomic<[MatrixRoomLink]>([])
    let joins = Atomic<[MatrixLinkedRoom]>([])
    let knocks = Atomic(0)
    let fail = Atomic(false)
    let readGate = Atomic<ProfileTestRequest<MatrixLinkedRoom>?>(nil)
    let writeGate = Atomic<ProfileTestRequest<MatrixLinkedRoom>?>(nil)

    func load(_ link: MatrixRoomLink) async throws -> MatrixLinkedRoom {
        reads.modify { $0 += 1 }
        links.modify { $0.append(link) }
        if let gate = readGate.wrappedValue { return try await gate.wait() }
        if fail.wrappedValue { throw URLError(.notConnectedToInternet) }
        return value.wrappedValue
    }
    func join(_ preview: MatrixLinkedRoom) async throws -> MatrixLinkedRoom {
        joins.modify { $0.append(preview) }
        if let gate = writeGate.wrappedValue { return try await gate.wait() }
        if fail.wrappedValue { throw URLError(.notConnectedToInternet) }
        var result = preview
        result.info.membership = .joined
        value.wrappedValue = result
        return result
    }
    func knock(_ preview: MatrixLinkedRoom) async throws { knocks.modify { $0 += 1 } }
}

/// Intentionally ignores cancellation, like an in-flight SDK await can.
/// Tests advance deadlines explicitly instead of sleeping in wall-clock time.
private actor MatrixLinkTestClock {
    private var waits: [(Duration, CheckedContinuation<Void, Error>?)] = []
    var durations: [Duration] { waits.map { $0.0 } }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { waits.append((duration, $0)) }
    }

    func fire(_ index: Int) {
        let continuation = waits[index].1
        waits[index].1 = nil
        continuation?.resume()
    }

    func finish() { for index in waits.indices { fire(index) } }
}

private final class MatrixLinkSDKPreview: RoomPreview, @unchecked Sendable {
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func info() -> RoomPreviewInfo { linkedRoom().info }
}

private final class MatrixLinkSDKRoom: Room, @unchecked Sendable {
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
}

private final class MatrixLinkSDKClient: Client, @unchecked Sendable {
    let aliasReads = Atomic<[String]>([])
    let previews = Atomic<[(String, [String])]>([])
    let joins = Atomic<[(String, [String])]>([])
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError() }
    override func getRoom(roomId: String) throws -> Room? { #expect(!Thread.isMainThread); return nil }
    override func resolveRoomAlias(roomAlias: String) async throws -> ResolvedRoomAlias? {
        aliasReads.modify { $0.append(roomAlias) }
        return ResolvedRoomAlias(roomId: "!linked:example.org", servers: ["b.org", "c.org"])
    }
    override func getRoomPreviewFromRoomId(roomId: String, viaServers: [String]) async throws -> RoomPreview {
        previews.modify { $0.append((roomId, viaServers)) }
        return MatrixLinkSDKPreview()
    }
    override func joinRoomByIdOrAlias(roomIdOrAlias: String, serverNames: [String]) async throws -> Room {
        joins.modify { $0.append((roomIdOrAlias, serverNames)) }
        return MatrixLinkSDKRoom()
    }
}

@Suite("Matrix links", .serialized)
struct MatrixLinkTests {
    @Test("SDK resolution keeps routing hints; joining uses the previewed ID, not a mutable alias")
    @MainActor
    func sdkResolution() async throws {
        let client = MatrixLinkSDKClient(), source = SDKMatrixRoomLinkSource(client: client)
        let preview = try await source.load(.init(reference: "#alias:example.org", via: ["a.org", "b.org"]))
        #expect(client.aliasReads.wrappedValue == ["#alias:example.org"])
        #expect(client.previews.wrappedValue.first?.0 == "!linked:example.org")
        #expect(client.previews.wrappedValue.first?.1 == ["a.org", "b.org", "c.org"])
        #expect(client.joins.wrappedValue.isEmpty)
        let joined = try await source.join(preview)
        #expect(joined.info.membership == .joined && joined.room != nil)
        #expect(client.joins.wrappedValue.first?.0 == "!linked:example.org")
        #expect(client.joins.wrappedValue.first?.1 == ["a.org", "b.org", "c.org"])
        #expect(client.aliasReads.wrappedValue.count == 1)
    }

    @Test("The SDK decodes person links once and keeps Matrix URIs compatible", arguments: [
        "https://matrix.to/#/@alice:example.org", "https://matrix.to/#/%40alice%3Aexample.org",
        "matrix:u/alice:example.org", "MATRIX:u/alice:example.org",
        "https://matrix.to/#/@alice:example.org?client=element.io"
    ])
    func person(_ text: String) throws {
        #expect(MatrixLink.parse(try #require(URL(string: text))) == .person("@alice:example.org"))
    }

    @Test("Room and event links preserve via servers and aliases", arguments: [
        "https://matrix.to/#/!room:example.org/$event?via=a.org&via=b.org",
        "https://matrix.to/#/!room:example.org/$event?client=element.io&via=a.org&via=b.org&web-instance=https%3A%2F%2Fapp.element.io",
        "matrix:roomid/room:example.org/e/event?via=a.org&via=b.org"
    ])
    func event(_ text: String) throws {
        #expect(MatrixLink.parse(try #require(URL(string: text))) == .room(.init(
            reference: "!room:example.org", via: ["a.org", "b.org"], eventID: "$event")))
        #expect(MatrixLink.parse(URL(string: "https://matrix.to/#/%23room:example.org/$event")!) == .room(
            .init(reference: "#room:example.org", via: [], eventID: "$event")))
    }

    @Test("Lookalike websites, credentials and unsupported links cannot become internal routes", arguments: [
        "https://matrix.to.evil.org/#/@alice:example.org", "https://matrix.to@evil.org/#/@alice:example.org",
        "https://evil.org/#/@alice:example.org", "https://matrix.to/help#/@alice:example.org",
        "https://user@matrix.to/#/@alice:example.org", "javascript:alert(1)",
        "matrix:garbage", "https://matrix.to/#/garbage", "https://matrix.to/"
    ])
    func rejected(_ text: String) throws {
        #expect(MatrixLink.parse(try #require(URL(string: text))) == nil)
    }

    @Test("Percent-encoded reserved characters in generated user links are decoded exactly once")
    func generatedPerson() throws {
        let id = "@a/b:example.org"
        let link = try matrixToUserPermalink(userId: id)
        #expect(MatrixLink.parse(try #require(URL(string: link + "?client=element.io"))) == .person(id))
    }

    @Test("Copied links and Matrix URIs are clickable in plain text and explicit HTML", arguments: [
        "https://matrix.to/#/%23group:example.org", "https://matrix.to/#/!room:example.org/$event?via=a.org&via=b.org",
        "matrix:u/alice:example.org", "matrix:roomid/room:example.org/e/event?via=a.org&via=b.org"
    ])
    func rendered(_ link: String) throws {
        let plain = MatrixRichTextParser.parse(body: "🙂 \(link) now", metadata: nil)
        #expect(plain.links.count == 1)
        let detected = try #require(plain.links.first)
        #expect((plain.text as NSString).substring(with: detected.range) == link)
        #expect(MatrixLink.parse(URL(string: detected.destination)!) == MatrixLink.parse(URL(string: link)!))
        let explicit = MatrixRichTextParser.parse(body: "Open", metadata: ChatTextMetadata(
            format: ChatTextMetadata.matrixHTMLFormat,
            formattedBody: "<a href=\"\(link.replacingOccurrences(of: "&", with: "&amp;"))\">Open</a>"))
        #expect(explicit.links.count == 1)
        #expect(explicit.links.first?.origin == .explicit)
        #expect(RichTextURLPolicy.destination(from: link) != nil)
    }

    @Test("Access rules require an explicit join or knock", arguments: [false, true])
    func access(allowed: Bool) {
        #expect(linkedRoom(membership: .joined).action == .open)
        #expect(linkedRoom(membership: .invited, rule: .invite).action == .join)
        #expect(linkedRoom(membership: .banned).action == nil)
        #expect(linkedRoom(membership: .knocked, rule: .knock).action == nil)
        #expect(linkedRoom(rule: .invite).action == nil)
        #expect(linkedRoom(rule: .private).action == nil)
        #expect(linkedRoom(rule: .custom(repr: "custom")).action == nil)
        #expect(linkedRoom(rule: .knock).action == .knock)
        #expect(linkedRoom(rule: .restricted(rules: []), allowed: allowed).action == (allowed ? .join : nil))
        #expect(linkedRoom(rule: .knockRestricted(rules: []), allowed: allowed).action == (allowed ? .join : .knock))
    }

    @MainActor
    private func model(_ source: MatrixLinkTestSource, current: @escaping () -> Bool = { true }) -> MatrixRoomLinkModel {
        MatrixRoomLinkModel(link: .init(reference: "#linked:example.org", via: []),
                            source: source, isCurrentSession: current)
    }

    @MainActor
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition())
    }

    @Test("Joined rooms open directly after resolving, with no preview and no duplicate request", arguments: [false, true])
    @MainActor
    func automaticOpen(message: Bool) async throws {
        let source = MatrixLinkTestSource(), gate = ProfileTestRequest<MatrixLinkedRoom>()
        source.value.wrappedValue = linkedRoom(membership: .joined)
        source.readGate.wrappedValue = gate
        let eventID = message ? "$event" : nil
        let value = MatrixRoomLinkModel(link: .init(reference: "#alias:example.org", via: [], eventID: eventID),
            source: source, isCurrentSession: { true })
        var requested: [String?] = [], opens = 0, previews = 0
        value.prepareOpen = { _, event in
            requested.append(event)
            return PreparedPollNavigation { opens += 1; return true }
        }
        value.onNeedsPreview = { previews += 1 }
        value.onReady = { _ = $0.open() }
        value.start(); value.start(); value.reload()
        try await wait { await gate.isPending }
        #expect(value.isBusy && previews == 0 && opens == 0)
        await gate.finish(source.value.wrappedValue)
        await value.waitForOperationForTesting()
        #expect(requested == [eventID] && opens == 1 && previews == 0)
        #expect(source.reads.wrappedValue == 1 && source.joins.wrappedValue.isEmpty)
        value.stop()
    }

    @Test("Previewing never joins, double taps send one join, and successful retries do not rejoin")
    @MainActor
    func explicitJoin() async throws {
        let source = MatrixLinkTestSource(), value = model(source), gate = ProfileTestRequest<MatrixLinkedRoom>()
        var opens = 0, previews = 0, failOpen = true
        value.onNeedsPreview = { previews += 1 }
        value.prepareOpen = { _, _ in
            if failOpen { throw PollNavigationError.loadingFailed }
            return PreparedPollNavigation { opens += 1; return true }
        }
        value.onReady = { _ = $0.open() }
        value.start(); value.start()
        await value.waitForOperationForTesting()
        #expect(source.reads.wrappedValue == 1 && source.joins.wrappedValue.isEmpty && opens == 0 && previews == 1)
        source.writeGate.wrappedValue = gate
        value.performAction(); value.performAction()
        try await wait { await gate.isPending }
        source.value.wrappedValue = linkedRoom(membership: .joined)
        await gate.finish(source.value.wrappedValue)
        await value.waitForOperationForTesting()
        #expect(value.error != nil && source.joins.wrappedValue.count == 1)
        #expect(source.joins.wrappedValue.first?.via == ["relay.example.org"])
        failOpen = false
        value.performAction()
        await value.waitForOperationForTesting()
        #expect(opens == 1 && value.error == nil && source.joins.wrappedValue.count == 1)
        value.stop()
    }

    @Test("A knock is sent once and stays a pending request")
    @MainActor
    func knock() async {
        let source = MatrixLinkTestSource()
        source.value.wrappedValue = linkedRoom(rule: .knock)
        let value = model(source)
        value.start(); await value.waitForOperationForTesting()
        value.performAction(); await value.waitForOperationForTesting()
        value.performAction(); await value.waitForOperationForTesting()
        #expect(value.preview?.info.membership == .knocked && value.preview?.action == nil)
        #expect(source.knocks.wrappedValue == 1 && source.joins.wrappedValue.isEmpty)
        value.stop()
    }

    @Test("Leaving or changing accounts drops late preview and join results", arguments: [false, true], [false, true])
    @MainActor
    func cancellation(switchAccount: Bool, duringJoin: Bool) async throws {
        let source = MatrixLinkTestSource(), gate = ProfileTestRequest<MatrixLinkedRoom>()
        var active = true, opens = 0
        let value = model(source, current: { active })
        value.prepareOpen = { _, _ in PreparedPollNavigation { opens += 1; return true } }
        value.onReady = { _ = $0.open() }
        if !duringJoin { source.readGate.wrappedValue = gate }
        value.start()
        if duringJoin {
            await value.waitForOperationForTesting()
            source.writeGate.wrappedValue = gate
            value.performAction()
        }
        try await wait { await gate.isPending }
        if switchAccount { active = false } else { value.stop() }
        await gate.finish(linkedRoom(membership: .joined))
        await value.waitForOperationForTesting()
        #expect(opens == 0 && value.preview?.info.membership != .joined)
        value.stop()
    }

    @Test("Network errors leave the preview retryable")
    @MainActor
    func retry() async {
        let source = MatrixLinkTestSource(), value = model(source)
        source.fail.wrappedValue = true
        value.start(); await value.waitForOperationForTesting()
        #expect(value.error != nil && !value.isBusy)
        source.fail.wrappedValue = false
        value.reload(); await value.waitForOperationForTesting()
        #expect(value.error == nil && value.preview != nil)
        value.stop()
    }

    @Test("Superseding history navigation finishes the inline request and permits opening the same link again")
    @MainActor
    func supersededHistory() async throws {
        let database = try TimelineWriteFixture.database()
        let chat = ChatViewModel(testingRoomId: TimelineWriteFixture.roomID, dbQueue: database,
            window: MessageWindow(roomId: TimelineWriteFixture.roomID, dbQueue: database), mode: .normal)
        defer { chat.cleanup() }
        let source = MatrixLinkTestSource(), gate = ProfileTestRequest<HistoryPaginationResult>()
        source.value.wrappedValue = linkedRoom(membership: .joined)
        let value = model(source)
        defer { value.stop() }
        var loading: [Bool] = [], failures = 0, opens = 0
        func request() -> ChatLinkOpening {
            let request = ChatLinkOpening(url: URL(string: "https://matrix.to/#/!linked:example.org/$missing")!,
                onLoading: { loading.append($0) }, onFinish: {})
            request.onCancel = { value.stop() }
            value.onCancelled = { [weak request] in request?.cancel() }
            value.onReady = { [weak request] prepared in
                if prepared.open() { opens += 1; request?.finish() }
            }
            return request
        }
        let first = request()
        value.onFailure = { failures += 1 }
        value.prepareOpen = { _, _ in
            try await chat.preparePollNavigation(eventId: "$missing", targetKind: .message,
                paginate: { (try? await gate.wait()) ?? .cancelled })
        }
        value.start()
        try await wait { await gate.isPending }
        chat.cancelPendingHistoryReplacement()
        await gate.finish(.page(reachedStart: false))
        await value.waitForOperationForTesting()
        #expect(!first.isActive && !value.isBusy && value.error == nil)
        #expect(loading == [true, false] && opens == 0 && failures == 0)
        let second = request()
        value.prepareOpen = { _, _ in PreparedPollNavigation { true } }
        value.start(); await value.waitForOperationForTesting()
        #expect(!second.isActive && opens == 1 && failures == 0)
        #expect(loading == [true, false, true, false])
    }

    @Test("A stalled resolution times out without waiting for the SDK; retry ignores the old response")
    @MainActor
    func resolutionTimeout() async throws {
        let source = MatrixLinkTestSource(), clock = MatrixLinkTestClock()
        let gate = ProfileTestRequest<MatrixLinkedRoom>()
        source.readGate.wrappedValue = gate
        let value = MatrixRoomLinkModel(link: .init(reference: "#alias:example.org", via: []),
            source: source, isCurrentSession: { true }, waitForTimeout: { try await clock.sleep($0) })
        defer { value.stop() }
        var failures = 0, opens = 0
        value.onFailure = { failures += 1 }
        value.prepareOpen = { _, _ in PreparedPollNavigation { opens += 1; return true } }
        value.onReady = { _ = $0.open() }
        value.start()
        try await wait {
            let pending = await gate.isPending
            let durations = await clock.durations
            return pending && durations == [.seconds(10)]
        }
        let oldOperation = try #require(value.operationForTesting)
        await clock.fire(0)
        try await wait { value.error != nil && !value.isBusy }
        #expect(failures == 1 && value.preview == nil && opens == 0)
        #expect(await gate.isPending)
        source.readGate.wrappedValue = nil
        source.value.wrappedValue = linkedRoom(membership: .joined)
        value.retry(); await value.waitForOperationForTesting()
        #expect(value.error == nil && opens == 1 && value.preview?.action == .open)
        await gate.finish(linkedRoom(membership: .banned))
        await oldOperation.value
        #expect(value.preview?.action == .open && value.error == nil && failures == 1 && opens == 1)
        await clock.finish()
    }

    @Test("A cancelled resolution timer cannot expire history; a stalled history load has its own deadline")
    @MainActor
    func historyTimeout() async throws {
        let source = MatrixLinkTestSource(), clock = MatrixLinkTestClock()
        let read = ProfileTestRequest<MatrixLinkedRoom>(), preparation = ProfileTestRequest<Void>()
        source.readGate.wrappedValue = read
        source.value.wrappedValue = linkedRoom(membership: .joined)
        let value = MatrixRoomLinkModel(link: .init(reference: "!linked:example.org", via: [], eventID: "$event"),
            source: source, isCurrentSession: { true }, waitForTimeout: { try await clock.sleep($0) })
        defer { value.stop() }
        var failures = 0, opens = 0
        value.onFailure = { failures += 1 }
        value.prepareOpen = { _, event in
            if event != nil { try await preparation.wait() }
            return PreparedPollNavigation { opens += 1; return true }
        }
        value.onReady = { _ = $0.open() }
        value.start()
        try await wait {
            let pending = await read.isPending
            let durations = await clock.durations
            return pending && durations == [.seconds(10)]
        }
        await read.finish(source.value.wrappedValue)
        try await wait {
            let pending = await preparation.isPending
            let durations = await clock.durations
            return pending && durations == [.seconds(10), .seconds(35)]
        }
        let oldOperation = try #require(value.operationForTesting)
        await clock.fire(0)
        #expect(value.isBusy && value.error == nil)
        await clock.fire(1)
        try await wait { value.error != nil && !value.isBusy }
        #expect(failures == 1 && opens == 0 && value.preview?.action == .open)
        source.readGate.wrappedValue = nil
        value.openRoom(); await value.waitForOperationForTesting()
        #expect(value.error == nil && opens == 1)
        await preparation.finish(())
        await oldOperation.value
        #expect(opens == 1 && failures == 1)
        await clock.finish()
    }

    @Test("Leaving or changing accounts suppresses a pending link deadline", arguments: [false, true])
    @MainActor
    func cancelledTimeout(switchAccount: Bool) async throws {
        let source = MatrixLinkTestSource(), clock = MatrixLinkTestClock()
        let gate = ProfileTestRequest<MatrixLinkedRoom>()
        source.readGate.wrappedValue = gate
        var active = true, failures = 0
        let value = MatrixRoomLinkModel(link: .init(reference: "#alias:example.org", via: []),
            source: source, isCurrentSession: { active }, waitForTimeout: { try await clock.sleep($0) })
        value.onFailure = { failures += 1 }
        value.start()
        try await wait {
            let pending = await gate.isPending
            let durations = await clock.durations
            return pending && durations.count == 1
        }
        if switchAccount { active = false } else { value.stop() }
        await clock.fire(0)
        await gate.finish(linkedRoom())
        await value.waitForOperationForTesting()
        #expect(failures == 0 && value.error == nil && value.preview == nil)
        value.stop()
        await clock.finish()
    }

    @Test("A prepared event cannot commit after closing or replacing the request", arguments: [false, true])
    @MainActor
    func stalePreparation(close: Bool) async throws {
        let source = MatrixLinkTestSource()
        source.value.wrappedValue = linkedRoom(membership: .joined)
        let value = model(source)
        var prepared: PreparedPollNavigation?, commits = 0
        value.prepareOpen = { _, _ in PreparedPollNavigation { commits += 1; return true } }
        value.onReady = { prepared = $0 }
        value.start(); await value.waitForOperationForTesting()
        value.performAction(); await value.waitForOperationForTesting()
        let old = try #require(prepared)
        if close { value.stop() } else { value.reload(); await value.waitForOperationForTesting() }
        #expect(!old.open() && commits == 0)
        value.stop()
    }

    @Test("A failed event can retry the event or open just its room")
    @MainActor
    func unavailableEventFallback() async {
        let source = MatrixLinkTestSource()
        source.value.wrappedValue = linkedRoom(membership: .joined)
        let value = MatrixRoomLinkModel(link: .init(reference: "!linked:example.org", via: [], eventID: "$missing"),
            source: source, isCurrentSession: { true })
        var requested: [String?] = [], opens = 0
        value.prepareOpen = { _, event in
            requested.append(event)
            if event != nil { throw PollNavigationError.unavailable }
            return PreparedPollNavigation { opens += 1; return true }
        }
        value.onReady = { _ = $0.open() }
        value.start(); await value.waitForOperationForTesting()
        #expect(value.error != nil && opens == 0)
        value.retry(); await value.waitForOperationForTesting()
        value.openRoom(); await value.waitForOperationForTesting()
        #expect(requested == ["$missing", "$missing", nil] && opens == 1 && value.error == nil)
        #expect(source.joins.wrappedValue.isEmpty)
        #expect(source.links.wrappedValue.last?.reference == "!linked:example.org")
        #expect(source.links.wrappedValue.last?.via == ["relay.example.org"])
        value.stop()
    }

    @Test("Room routing keeps the source chat visible while resolving and skips joined previews",
          arguments: [false, true], [false, true])
    @MainActor
    func inlineRouting(joined: Bool, leaveBeforeResolution: Bool) async throws {
        let database = try TimelineWriteFixture.database()
        let roomID = TimelineWriteFixture.roomID
        let chatModel = ChatViewModel(testingRoomId: roomID, dbQueue: database,
            window: MessageWindow(roomId: roomID, dbQueue: database), mode: .normal)
        let audio = AudioPlayerService(), coordinator = ChatsCoordinator(audioPlayer: audio)
        let origin = ChatViewController(viewModel: chatModel, audioPlayer: audio)
        let navigation = coordinator.navigationController, root = UIViewController()
        navigation.setStack([root, origin], animated: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation; window.isHidden = false
        defer {
            navigation.setStack([root], animated: false)
            window.isHidden = true; window.rootViewController = nil; chatModel.cleanup()
        }
        navigation.view.layoutIfNeeded()
        var loading: [Bool] = []
        let request = ChatLinkOpening(url: URL(string: "https://matrix.to/#/!linked:example.org")!,
            onLoading: { loading.append($0) }, onFinish: {})
        defer { request.cancel() }
        let source = MatrixLinkTestSource(), gate = ProfileTestRequest<MatrixLinkedRoom>()
        source.readGate.wrappedValue = gate
        var resolved = linkedRoom(membership: joined ? .joined : nil)
        resolved.info.roomId = roomID
        if joined { resolved.room = MatrixLinkSDKRoom() }
        coordinator.openMatrixRoomLinkForTesting(.init(reference: roomID, via: []),
                                                 source: source, origin: origin, request: request)
        try await wait { await gate.isPending }
        #expect(navigation.topViewController === origin && navigation.stack.count == 2)
        #expect(loading == [true])
        let other = UIViewController()
        if leaveBeforeResolution { navigation.push(other) }
        await gate.finish(resolved)
        try await wait { !request.isActive && !navigation.isTransitionInFlight }
        #expect(loading == [true, false])
        if leaveBeforeResolution {
            #expect(navigation.topViewController === other && navigation.stack.count == 3)
        } else {
            #expect(navigation.stack.count == (joined ? 2 : 3))
            #expect((navigation.topViewController === origin) == joined)
        }
        #expect(source.joins.wrappedValue.isEmpty)
    }

    @Test("A failed navigation commit reports its error only once")
    @MainActor
    func routingFailureOnce() async {
        let source = MatrixLinkTestSource(), value = model(source)
        source.value.wrappedValue = linkedRoom(membership: .joined)
        var failures = 0
        value.prepareOpen = { _, _ in PreparedPollNavigation { false } }
        value.onReady = { if !$0.open() { value.routingFailed() } }
        value.onFailure = { failures += 1 }
        value.start(); await value.waitForOperationForTesting()
        #expect(failures == 1 && value.error != nil && !value.isBusy)
        value.onReady = nil
        value.stop()
    }

    @Test("Invalid web permalinks offer a browser fallback, unsupported Matrix URIs do not")
    func browserFallback() throws {
        let web = try #require(URL(string: "https://matrix.to/#/garbage"))
        #expect(MatrixLink.parse(web) == nil && MatrixLink.browserFallback(web) == web)
        #expect(MatrixLink.browserFallback(URL(string: "matrix:garbage")!) == nil)
        #expect(MatrixLink.browserFallback(URL(string: "https://matrix.to.evil.org/#/garbage")!) == nil)
        #expect(MatrixLink.browserFallback(URL(string: "https://user@matrix.to/#/garbage")!) == nil)
    }

    @Test("Deferred routes recheck the origin after a pop and don't stall later navigation")
    @MainActor
    func transitionGuard() async throws {
        let root = UIViewController(), origin = UIViewController(), next = UIViewController()
        let nav = ZynaNavigationController(rootViewController: root)
        nav.push(origin, animated: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = nav; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        nav.view.layoutIfNeeded()
        nav.pop()
        var routed = false
        nav.performWhenIdle { if nav.topViewController === origin { routed = true } }
        nav.push(next, animated: false)
        try await wait { !nav.isTransitionInFlight && nav.topViewController === next }
        #expect(!routed && nav.stack.count == 2)
    }
}
