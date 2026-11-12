//
//  test_lyric_offset.swift
//  lirik
//
//  Unit tests for LyricOffsetStore (per-video manual timing offsets).
//  Run with:
//    swiftc Tests/test_lyric_offset.swift \
//      lirik/Sources/Lyrics/LyricOffsetStore.swift \
//      -o /tmp/off_test && /tmp/off_test
//

import Foundation

@main
struct LyricOffsetTests {

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

    static func main() {
        let suiteName = "io.github.ridhaaf.lirik.offsetTests"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            print("  ❌ FAIL: could not create test defaults suite")
            exit(1)
        }
        suite.removePersistentDomain(forName: suiteName)

        print("Group 1: LyricOffsetStore")
        let store = LyricOffsetStore(defaults: suite)

        check(store.offset(forVideoId: "abc123") == 0, "unknown video defaults to zero")

        store.setOffset(17.5, forVideoId: "abc123")
        check(store.offset(forVideoId: "abc123") == 17.5, "round-trips positive offset")

        store.setOffset(-2.5, forVideoId: "abc123")
        check(store.offset(forVideoId: "abc123") == -2.5, "round-trips negative offset")

        store.setOffset(3.0, forVideoId: "other")
        check(store.offset(forVideoId: "abc123") == -2.5, "videos are independent")

        // A fresh instance over the same suite sees persisted values.
        let reopened = LyricOffsetStore(defaults: suite)
        check(reopened.offset(forVideoId: "other") == 3.0, "offset persists across instances")

        reopened.setOffset(0, forVideoId: "other")
        check(reopened.offset(forVideoId: "other") == 0, "zero reads back as zero")
        let residue = suite.dictionary(forKey: LyricOffsetStore.offsetsKey) as? [String: Double] ?? [:]
        check(residue["other"] == nil, "zero removes the entry instead of storing it")

        check(store.offset(forVideoId: "") == 0, "empty video ID reads zero")
        store.setOffset(9.0, forVideoId: "")
        check(store.offset(forVideoId: "") == 0, "empty video ID is a no-op write")

        suite.removePersistentDomain(forName: suiteName)

        print("\n══════════════════════════════════════════════════════")
        print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
        print("══════════════════════════════════════════════════════")

        if failCount > 0 {
            exit(1)
        }
    }
}
