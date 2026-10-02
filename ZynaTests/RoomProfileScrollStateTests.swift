// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
import Foundation
import CoreGraphics
@testable import Zyna

@Suite("Profile scroll session")
struct RoomProfileScrollStateTests {
    @Test func avatarFlickRequiresSpeedAndMeaningfulTravelInsideThePhoto() {
        let cases: [(travel: CGFloat, velocity: CGFloat, opens: Bool)] = [
            (20, -0.7, true), (20, -0.2, false), (6, -2, false),
            (20, 0.7, false), (50, 0, false), (80, 0, true)
        ]
        for value in cases {
            var drag = RoomProfileAvatarDrag(progress: 0)
            _ = drag.update(collapse: 300 - value.travel * RoomProfileAvatarDrag.scrollSpeed, expansion: 300)
            _ = drag.finish(velocity: value.velocity)
            #expect(drag.wantsExpanded == value.opens)
        }
        var fromList = RoomProfileAvatarDrag(progress: 0)
        _ = fromList.update(collapse: 450, expansion: 300)
        _ = fromList.finish(velocity: -2)
        #expect(!fromList.wantsExpanded)
    }

    @Test func avatarFlickSignalsTargetReversalWithoutDuplicateHaptics() {
        var drag = RoomProfileAvatarDrag(progress: 0)
        var haptic = drag.update(collapse: 190, expansion: 300)
        #expect(haptic && drag.wantsExpanded)
        // Still inside distance hysteresis, but a deliberate upward flick
        // reverses the decision instead of completing the earlier pull.
        haptic = drag.update(collapse: 220, expansion: 300)
        #expect(!haptic && drag.wantsExpanded)
        haptic = drag.finish(velocity: 0.7)
        #expect(haptic && !drag.wantsExpanded)
        haptic = drag.finish(velocity: 0.7)
        #expect(!haptic && !drag.wantsExpanded)

        var shortPull = RoomProfileAvatarDrag(progress: 0)
        _ = shortPull.update(collapse: 270, expansion: 300)
        haptic = shortPull.finish(velocity: -0.7)
        #expect(haptic && shortPull.wantsExpanded)
        haptic = shortPull.finish(velocity: -0.7)
        #expect(!haptic)

        var closing = RoomProfileAvatarDrag(progress: 1)
        _ = closing.update(collapse: 30, expansion: 300)
        haptic = closing.finish(velocity: 0.7)
        #expect(haptic && !closing.wantsExpanded)
    }

    @Test func avatarDragSpeedIsLocalReversibleAndIndependentOfCallbackCount() {
        func move(_ state: inout RoomProfileScrollState, by delta: CGFloat) {
            state.scroll(to: state.collapse + state.depth(for: .media) + delta, avatarScrollSpeed: 1.5)
        }
        var state = RoomProfileScrollState()
        state.resizeHeader(to: 220, avatarExpansionHeight: 300)
        state.scroll(to: 1200)
        move(&state, by: -200)
        #expect(state.collapse == 520 && state.depth(for: .media) == 480)
        // Consume the remaining content and ordinary header at 1x, then
        // turn the last 40 points of finger travel into 60 points of photo.
        move(&state, by: -740)
        #expect(state.collapse == 240 && state.depth(for: .media) == 0)
        move(&state, by: 40)
        #expect(state.collapse == 300)
        move(&state, by: -100)
        #expect(state.collapse == 150)
        var manyUpdates = state
        move(&state, by: 160)
        for _ in 0..<160 { move(&manyUpdates, by: 1) }
        #expect(state.collapse == 360)
        #expect(state.collapse == manyUpdates.collapse)
        move(&state, by: -160)
        #expect(state.collapse == 150)
        move(&state, by: -100)
        #expect(state.avatarProgress == 1)
    }

    @Test func loadingAndRemovingPhotoPreserveTheVisibleContent() {
        var state = RoomProfileScrollState()
        state.scroll(to: 1320)
        let contentY = state.headerHeight - state.collapse - state.depth(for: .media)
        state.resizeHeader(to: 220, avatarExpansionHeight: 302)
        #expect(state.avatarProgress == 0)
        #expect(state.regularCollapse == 220)
        #expect(state.depth(for: .media) == 1100)
        #expect(state.headerHeight - state.collapse - state.depth(for: .media) == contentY)
        state.resizeHeader(to: 220, avatarExpansionHeight: 0)
        #expect(state.headerHeight - state.collapse - state.depth(for: .media) == contentY)

        state.scroll(to: 0)
        state.resizeHeader(to: 220, avatarExpansionHeight: 302)
        #expect(state.collapse == 302)
        #expect(state.avatarProgress == 0)
        #expect(state.regularCollapse == 0)
        #expect(state.headerHeight - state.collapse == 220)
    }

    @Test func squareAvatarClosesDuringPagingAndRestoresOnCancellation() {
        var state = RoomProfileScrollState()
        state.resizeHeader(to: 220, avatarExpansionHeight: 302)
        state.scroll(to: 1422)
        state.beginTransition()
        state.finishTransition(at: .files)
        state.scroll(to: 0)
        #expect(state.avatarProgress == 1)
        state.beginTransition()
        state.transition(to: .media, progress: 0.25)
        #expect(state.avatarProgress > 0 && state.avatarProgress < 1)
        #expect(state.regularCollapse == 0)
        state.transition(to: .media, progress: 0.75)
        #expect(state.avatarProgress == 0)
        #expect(state.regularCollapse > 0)
        state.transition(to: .media, progress: 0.1)
        #expect(state.avatarProgress > 0.8)
        state.finishTransition(at: .files)
        #expect(state.avatarProgress == 1)
        #expect(state.depth(for: .media) == 900)
        state.beginTransition()
        state.finishTransition(at: .media)
        #expect(state.avatarProgress == 0)
        #expect(state.regularCollapse == 220)
        #expect(state.depth(for: .media) == 900)
    }

    @Test func resizingKeepsAvatarProgressAndContentDepthIndependent() {
        var state = RoomProfileScrollState()
        state.resizeHeader(to: 220, avatarExpansionHeight: 220)
        state.setHeaderCollapse(110)
        state.restoreDepth(800, for: .files)
        state.resizeHeader(to: 260, avatarExpansionHeight: 302)
        #expect(state.avatarProgress == 0.5)
        #expect(state.regularCollapse == 0)
        #expect(state.depth(for: .files) == 800)
        state.setHeaderCollapse(302 + 130)
        state.resizeHeader(to: 300, avatarExpansionHeight: 220)
        #expect(state.regularCollapseProgress == 0.5)
        #expect(state.avatarProgress == 0)
        state.resizeHeader(to: 300, avatarExpansionHeight: 0)
        #expect(state.collapse == 150)
    }

    @Test func avatarThresholdSignalsEveryTargetChangeWithHysteresis() {
        var opening = RoomProfileAvatarDrag(progress: 0)
        var haptic = opening.update(collapse: 222, expansion: 302)
        #expect(!haptic)
        #expect(!opening.wantsExpanded)
        haptic = opening.update(collapse: 200, expansion: 302)
        #expect(haptic)
        #expect(opening.wantsExpanded)
        haptic = opening.update(collapse: 210, expansion: 302)
        #expect(!haptic)
        #expect(opening.wantsExpanded)
        haptic = opening.update(collapse: 230, expansion: 302)
        #expect(haptic)
        #expect(!opening.wantsExpanded)
        haptic = opening.update(collapse: 220, expansion: 302)
        #expect(!haptic)
        #expect(!opening.wantsExpanded)
        haptic = opening.update(collapse: 190, expansion: 302)
        #expect(haptic)
        #expect(opening.wantsExpanded)
        haptic = opening.update(collapse: 180, expansion: 302)
        #expect(!haptic)
        #expect(opening.wantsExpanded)

        var closing = RoomProfileAvatarDrag(progress: 1)
        haptic = closing.update(collapse: 80, expansion: 302)
        #expect(!haptic)
        #expect(closing.wantsExpanded)
        haptic = closing.update(collapse: 100, expansion: 302)
        #expect(haptic)
        #expect(!closing.wantsExpanded)
        haptic = closing.update(collapse: 50, expansion: 302)
        #expect(haptic)
        #expect(closing.wantsExpanded)
        haptic = closing.update(collapse: 90, expansion: 302)
        #expect(!haptic)
        #expect(closing.wantsExpanded)
        haptic = closing.update(collapse: 100, expansion: 302)
        #expect(haptic)
        #expect(!closing.wantsExpanded)
        var placeholder = RoomProfileAvatarDrag(progress: 0)
        haptic = placeholder.update(collapse: 0, expansion: 0)
        #expect(!haptic)
        #expect(!placeholder.wantsExpanded)
    }

    @Test func floatingPhotoMeetsTheHeaderBodyThroughoutExpansion() {
        for width: CGFloat in [320, 402, 874] {
            let extra = RoomProfileAvatarGeometry.expansionHeight(width: width)
            for progress: CGFloat in [0, 0.2, 0.5, 0.8, 1] {
                let rect = RoomProfileAvatarGeometry.frame(width: width, top: 100, progress: progress, collapse: 0)
                #expect(abs(rect.midX - width / 2) < 0.001)
                #expect(abs(rect.maxY - (100 + extra * progress + 12 + 88)) < 0.001)
                #expect(rect.width == rect.height)
                if progress == 1 { #expect(rect == CGRect(x: 0, y: 100, width: width, height: width)) }
            }
        }
    }

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

    @Test(arguments: [CGFloat(0), 302])
    func topButtonOpensRegularHeaderAndOnlyResetsSelectedSection(expansion: CGFloat) {
        var state = RoomProfileScrollState()
        state.resizeHeader(to: 220, avatarExpansionHeight: expansion)
        state.scroll(to: expansion + 1020)
        state.beginTransition()
        state.finishTransition(at: .files)
        state.scroll(to: expansion + 520)
        state.scrollToBeginning()
        #expect(state.depth(for: .files) == 0)
        #expect(state.depth(for: .media) == 800)
        #expect(state.regularCollapse == 0)
        #expect(state.avatarProgress == 0)
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
