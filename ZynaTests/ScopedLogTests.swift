//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
@testable import Zyna

@Suite("Lazy scoped diagnostics")
struct ScopedLogTests {
    @Test("A disabled log never constructs its payload")
    func disabled() {
        let log = ScopedLog(.none, mode: .any)
        var evaluations = 0
        func payload() -> String { evaluations += 1; return "unused" }
        #expect(!log.isEnabled)
        log("Value: \(payload())")
        #expect(evaluations == 0)
    }

    @Test("An enabled log constructs its payload once and preserves all-scope semantics")
    func enabled() {
        // The empty set is a subset of every configuration. These tests
        // don't mutate the global log scopes used by concurrent tests.
        let log = ScopedLog(.none, prefix: "[LogTest]", mode: .all)
        var evaluations = 0
        func payload() -> String { evaluations += 1; return "Lazy payload probe" }
        #if DEBUG
        #expect(log.isEnabled)
        log(payload())
        #expect(evaluations == 1)
        #else
        #expect(!log.isEnabled)
        log(payload())
        #expect(evaluations == 0)
        #endif
    }
}
