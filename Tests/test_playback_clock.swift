//
//  test_playback_clock.swift
//  lirik
//
//  Unit tests for PlaybackEstimate — the locally advanced position used by
//  browsers that can't report one (Firefox, Arc, JS-from-Apple-Events off).
//  Compiles against the REAL source — run with:
//    swiftc Tests/test_playback_clock.swift \
//      lirik/Sources/NowPlaying/PlaybackEstimate.swift \
//      -o /tmp/clock_test && /tmp/clock_test
//
//  Time is injected, so nothing here sleeps.
//

import Foundation

@main
struct PlaybackEstimateTests {

    static var passCount = 0
    static var failCount = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            passCount += 1
            print("  ✅ \(message)")
        } else {
            failCount += 1
            print("  ❌ FAIL: \(message)")
        }
    }

    static func checkClose(_ actual: TimeInterval, _ expected: TimeInterval, _ message: String) {
        check(abs(actual - expected) < 0.001, "\(message) (got: \(actual), expected: \(expected))")
    }

    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // ─── Group 1: first sight starts at zero ───────────────────

        print("Group 1: first sight")

        var clock = PlaybackEstimate()
        checkClose(clock.elapsed(forKey: "a", at: t0), 0, "first observation reports 0")
        check(clock.key == "a", "clock remembers the key")
        check(clock.startedAt == t0, "clock anchors at first observation")

        // ─── Group 2: advances with wall clock ─────────────────────

        print("\nGroup 2: advance")

        checkClose(clock.elapsed(forKey: "a", at: t0.addingTimeInterval(12.5)), 12.5, "advances by elapsed wall time")
        checkClose(clock.elapsed(forKey: "a", at: t0.addingTimeInterval(60)), 60, "keeps advancing")
        checkClose(clock.elapsed(forKey: "a", at: t0.addingTimeInterval(60)), 60, "repeated read at same instant is stable")

        // ─── Group 3: track change restarts ────────────────────────

        print("\nGroup 3: track change")

        checkClose(clock.elapsed(forKey: "b", at: t0.addingTimeInterval(90)), 0, "new key restarts the clock")
        checkClose(clock.elapsed(forKey: "b", at: t0.addingTimeInterval(95)), 5, "new key advances from its own anchor")
        checkClose(clock.elapsed(forKey: "a", at: t0.addingTimeInterval(100)), 0, "switching back restarts rather than resuming")

        // ─── Group 4: reset ────────────────────────────────────────

        print("\nGroup 4: reset")

        clock.reset()
        check(clock.key == nil, "reset clears the key")
        check(clock.startedAt == nil, "reset clears the anchor")
        checkClose(clock.elapsed(forKey: "b", at: t0.addingTimeInterval(200)), 0, "after reset the next track starts at 0")

        // ─── Group 5: clock skew ───────────────────────────────────

        print("\nGroup 5: backwards clock")

        var skewed = PlaybackEstimate()
        _ = skewed.elapsed(forKey: "a", at: t0)
        checkClose(skewed.elapsed(forKey: "a", at: t0.addingTimeInterval(-30)), 0, "backwards wall clock clamps to 0, never negative")

        // ─── Group 6: independent instances ────────────────────────

        print("\nGroup 6: independence")

        var one = PlaybackEstimate()
        var two = PlaybackEstimate()
        _ = one.elapsed(forKey: "x", at: t0)
        checkClose(two.elapsed(forKey: "y", at: t0.addingTimeInterval(10)), 0, "separate clocks don't share state")
        checkClose(one.elapsed(forKey: "x", at: t0.addingTimeInterval(10)), 10, "first clock unaffected by second")

        print("\n══════════════════════════════════════════════════════")
        print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
        print("══════════════════════════════════════════════════════")

        if failCount > 0 {
            exit(1)
        }
    }
}
