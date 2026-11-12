//
//  test_firefox_tabs.swift
//  lirik
//
//  Unit tests for FirefoxTabReader. Compiles against the REAL sources, run
//  with:
//    swiftc Tests/test_firefox_tabs.swift \
//      lirik/Sources/NowPlaying/FirefoxTabReader.swift \
//      lirik/Sources/NowPlaying/BrowserTabPoller.swift \
//      lirik/Sources/NowPlaying/NowPlayingTrack.swift \
//      lirik/Sources/NowPlaying/PlaybackEstimate.swift \
//      lirik/Sources/Lyrics/YouTubeCaptionsClient.swift \
//      lirik/Sources/Lyrics/LRCParser.swift \
//      lirik/Sources/Lyrics/LRCLIBClient.swift \
//      -o /tmp/firefox_test && /tmp/firefox_test
//
//  Reading the real AX tree is manual QA only per AGENTS.md §9; it needs a
//  running Firefox with Accessibility permission granted. Everything pure
//  (title recognition, artist/title split, target list) is covered here.
//

import Foundation

@main
struct FirefoxTabReaderTests {

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

    static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, "\(message) (got: \(actual))")
    }

    static func main() {
        // ─── Group 1: isYouTubeTitle ───────────────────────────────

        print("Group 1: FirefoxTabReader.isYouTubeTitle")

        check(FirefoxTabReader.isYouTubeTitle("Taylor Swift - Anti-Hero (Official Music Video) - YouTube"), "standard watch title")
        check(FirefoxTabReader.isYouTubeTitle("Daft Punk - Around the World - YouTube Music"), "YouTube Music video title")
        check(FirefoxTabReader.isYouTubeTitle("  Artist - Song - YouTube  "), "surrounding whitespace tolerated")

        check(!FirefoxTabReader.isYouTubeTitle("YouTube"), "bare YouTube title has no track info")
        check(!FirefoxTabReader.isYouTubeTitle("YouTube Music"), "bare YouTube Music title has no track info")
        check(!FirefoxTabReader.isYouTubeTitle("Artist - Song"), "title without the site suffix is not YouTube")
        check(!FirefoxTabReader.isYouTubeTitle("YouTube - Some Other Site"), "suffix must be at the end")
        check(!FirefoxTabReader.isYouTubeTitle(""), "empty title is not YouTube")
        check(!FirefoxTabReader.isYouTubeTitle("   "), "blank title is not YouTube")
        check(!FirefoxTabReader.isYouTubeTitle("GitHub - RidhaAF/lirik"), "unrelated tab is not YouTube")

        // ─── Group 2: title split for Firefox titles ───────────────

        print("\nGroup 2: splitArtistTitle on Firefox tab titles")

        var split = BrowserTabPoller.splitArtistTitle(from: "Taylor Swift - Anti-Hero (Official Music Video) - YouTube")
        checkEqual(split.artist, "Taylor Swift", "artist split")
        checkEqual(split.title, "Anti-Hero (Official Music Video)", "title keeps noise for cleanTrackTitle")

        split = BrowserTabPoller.splitArtistTitle(from: "Daft Punk - Around the World - YouTube Music")
        checkEqual(split.artist, "Daft Punk", "YouTube Music suffix stripped")
        checkEqual(split.title, "Around the World", "YouTube Music title split")

        split = BrowserTabPoller.splitArtistTitle(from: "Never Gonna Give You Up - YouTube")
        checkEqual(split.artist, "Unknown Artist", "no separator falls back to Unknown Artist")
        checkEqual(split.title, "Never Gonna Give You Up", "full title kept when no separator")

        // ─── Group 3: supported applications ───────────────────────

        print("\nGroup 3: FirefoxTabReader.Target")

        let targets = FirefoxTabReader.Target.all
        check(targets.count >= 1, "at least one Firefox-family browser listed")
        check(targets.contains { $0.bundleIdentifier == "org.mozilla.firefox" }, "Firefox itself is listed")
        checkEqual(Set(targets.map(\.bundleIdentifier)).count, targets.count, "bundle identifiers are unique")
        check(targets.allSatisfy { !$0.displayName.isEmpty }, "every target has a display name")
        check(!targets.contains { $0.bundleIdentifier == "com.google.Chrome" }, "Chromium browsers are not in the Firefox list")

        print("\n══════════════════════════════════════════════════════")
        print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
        print("══════════════════════════════════════════════════════")

        if failCount > 0 {
            exit(1)
        }
    }
}
