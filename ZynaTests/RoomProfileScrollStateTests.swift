// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
import Foundation
@testable import Zyna

@Suite("Profile scroll session")
struct RoomProfileScrollStateTests {
    @Test func zoomDepthDoesNotSnapAnExpandedHeaderOnTheNextScroll() {
        var state = RoomProfileScrollState()
        state.scroll(to: 80)
        state.restoreDepth(150, for: .media)
        state.scroll(to: 231)
        #expect(state.collapse == 81)
        #expect(state.depth(for: .media) == 150)
        state.scroll(to: 230)
        #expect(state.collapse == 81)
        #expect(state.depth(for: .media) == 149)
    }

    @Test func shortSectionExpansionPreservesMediaAndCollapseFollowsSwipe() {
        var state = RoomProfileScrollState()
        state.scroll(to: 1420)
        state.beginTransition()
        state.transition(to: .files, progress: 1)
        state.finishTransition(at: .files)
        #expect(state.collapse == 220)
        state.scroll(to: 0)
        #expect(state.depth(for: .media) == 1200)
        state.beginTransition()
        state.transition(to: .media, progress: 0.5)
        #expect(state.collapse == 110)
        state.transition(to: .media, progress: 0.25)
        #expect(state.collapse == 55)
        state.finishTransition(at: .files)
        #expect(state.collapse == 0)
        #expect(state.depth(for: .media) == 1200)
        state.beginTransition()
        state.transition(to: .media, progress: 1)
        state.finishTransition(at: .media)
        #expect(state.collapse == 220)
        #expect(state.depth(for: .media) == 1200)
    }

    @Test func topButtonOnlyResetsSelectedSection() {
        var state = RoomProfileScrollState()
        state.scroll(to: 1020)
        state.beginTransition()
        state.finishTransition(at: .files)
        state.scroll(to: 520)
        state.scrollToBeginning()
        #expect(state.depth(for: .files) == 0)
        #expect(state.depth(for: .media) == 800)
        #expect(state.collapse == 220)
    }

    @Test func programmaticGeometryCannotOverwritePositionDuringTransition() {
        var state = RoomProfileScrollState()
        state.scroll(to: 920)
        state.beginTransition()
        state.scroll(to: 0)
        #expect(state.depth(for: .media) == 700)
        state.finishTransition(at: .media)
        #expect(state.collapse == 220)
    }

    @Test func anchorSurvivesInsertsAndFallsBackAfterDeletion() {
        let anchor = RoomProfileAnchor(id: "b", previousIndex: 1, offset: 17)
        #expect(anchor.resolve(in: ["new", "a", "b", "c"]) == 2)
        #expect(anchor.resolve(in: ["a", "c"]) == 1)
        #expect(anchor.resolve(in: ["a"]) == 0)
        #expect(anchor.resolve(in: []) == nil)
    }

    @Test func headerResizePreservesDepthAndReversibleTransitionProgress() {
        var state = RoomProfileScrollState()
        state.scroll(to: 920)
        state.beginTransition()
        state.finishTransition(at: .files)
        state.scroll(to: 110)
        state.beginTransition()
        state.transition(to: .media, progress: 0.5)
        state.resizeHeader(to: 440)
        #expect(state.collapse == 330)
        #expect(state.depth(for: .media) == 700)
        state.finishTransition(at: .files)
        #expect(state.collapse == 220)
        #expect(state.depth(for: .files) == 0)
    }
}
