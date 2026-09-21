//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Testing
import UIKit
@testable import Zyna

@Suite("Scroll rendering", .serialized)
@MainActor
struct ScrollRenderingTests {
    @Test("Adaptive colors preserve Texture text and layout", arguments: [false, true])
    func adaptiveTitle(voice: Bool) throws {
        let title = PresenceTitleNode()
        title.name = "Chat title"
        title.memberCount = 42
        if voice {
            title.voiceState = VoiceTitleState(
                title: "Voice title", subtitle: "Sender", remainingText: "0:15", rateText: "1x",
                waveform: [], progress: 0.5, isPlaying: true, isLoading: false
            )
            title.voiceExpanded = true
        }
        title.applyGlassAdaptiveMaterial(.light)
        let range = ASSizeRange(
            min: CGSize(width: 340, height: 70), max: CGSize(width: 340, height: 70)
        )
        let layout = title.layoutThatFits(range)
        title.frame = CGRect(origin: .zero, size: layout.size)
        _ = title.view
        title.layoutIfNeeded()
        let settledLayout = title.layoutThatFits(range)
        let nodes = textNodes(in: title).filter { ($0.attributedText?.length ?? 0) > 0 }
        #expect(!nodes.isEmpty)
        let strings = try nodes.map { try #require($0.attributedText) }

        for material in [
            GlassAdaptiveMaterial(appearance: 1, contrast: 1),
            GlassAdaptiveMaterial(appearance: 0, contrast: 1),
            GlassAdaptiveMaterial(appearance: 0.5, contrast: 0)
        ] {
            title.applyGlassAdaptiveMaterial(material)
            #expect(title.layoutThatFits(range) === settledLayout)
            for (node, text) in zip(nodes, strings) {
                #expect(node.attributedText === text)
                #expect(node.textColorFollowsTintColor)
                #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
                let expectedColor = switch text.string {
                case "Chat title", "Voice title": material.primaryForeground
                case "1x": material.glyphForeground
                default: material.secondaryForeground
                }
                #expect(node.tintColor == expectedColor)
            }
        }
    }

    @Test("Online keeps its semantic color as the glass appearance changes")
    func onlineStatus() throws {
        let title = PresenceTitleNode()
        title.name = "Chat title"
        title.presence = UserPresence(online: true, lastSeen: nil)
        title.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
        _ = title.view
        title.layoutIfNeeded()
        let status = try #require(textNodes(in: title).first {
            $0.attributedText?.string == String(localized: "online")
        })
        title.applyGlassAdaptiveMaterial(GlassAdaptiveMaterial(appearance: 0, contrast: 1))
        #expect(status.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? UIColor == .systemGreen)
        title.presence = nil
        title.connectionStatus = "Connecting"
        #expect(status.attributedText?.string == "Connecting")
        #expect(status.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(status.tintColor == GlassAdaptiveMaterial(appearance: 0, contrast: 1).secondaryForeground)
    }

    @Test("Date caching expires at midnight, across DST and after a time zone change")
    func dateBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        #expect(nextDay.timeIntervalSince(day) == 23 * 60 * 60)
        var cache = DateHeaderModelCache()
        let today = cache.model(for: day, calendar: calendar, now: day)
        #expect(cache.model(for: day.addingTimeInterval(12 * 60 * 60), calendar: calendar,
                            now: nextDay.addingTimeInterval(-1)) == today)
        let yesterday = cache.model(for: day, calendar: calendar, now: nextDay)
        #expect(yesterday.id == today.id)
        #expect(yesterday.title != today.title)
        #expect(yesterday == DateDividerModel.make(for: day, calendar: calendar, now: nextDay))
        #expect(cache.model(for: nextDay, calendar: calendar, now: nextDay).id != today.id)

        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(cache.model(for: nextDay, calendar: calendar, now: nextDay)
            == DateDividerModel.make(for: nextDay, calendar: calendar, now: nextDay))
    }

    @Test("A reused date header remeasures a changed title and available width")
    func dateHeaderSizing() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let table = UITableView(frame: host.bounds)
        let dataSource = SingleRowDataSource()
        table.dataSource = dataSource
        table.rowHeight = 44
        table.estimatedRowHeight = 0
        host.addSubview(table)
        table.reloadData()
        table.layoutIfNeeded()
        let manager = DateHeaderOverlayManager()
        host.addSubview(manager.containerView)
        func update(_ text: String, width: CGFloat) {
            manager.update(
                viewport: CGRect(x: 0, y: 0, width: width, height: 400),
                rows: [.dateDivider(DateDividerModel(id: "day", date: Date(), title: text))],
                visibleIndexPaths: [IndexPath(row: 0, section: 0)], tableView: table,
                hostView: host, isScrolling: true, animated: false
            )
        }
        update("Today", width: 320)
        let header = try #require(manager.containerView.subviews.first)
        let label = try #require(header.subviews.first as? UILabel)
        let initialWidth = header.frame.width
        update("September 21, 2026", width: 320)
        #expect(label.text == "September 21, 2026")
        #expect(header.frame.width > initialWidth)
        let wideWidth = header.frame.width
        update("September 21, 2026", width: 80)
        #expect(header.frame.width <= 48)
        update("September 21, 2026", width: 320)
        #expect(header.frame.width == wideWidth)
        #expect(manager.containerView.subviews.first === header)
    }

    private func textNodes(in node: ASDisplayNode) -> [ASTextNode] {
        (node as? ASTextNode).map { [$0] } ?? (node.subnodes ?? []).flatMap { textNodes(in: $0) }
    }

    private final class SingleRowDataSource: NSObject, UITableViewDataSource {
        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }
        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            UITableViewCell()
        }
    }
}
