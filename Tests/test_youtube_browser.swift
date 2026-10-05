//
//  test_youtube_browser.swift
//  lirik
//
//  Unit tests for YouTube browser support. Compiles against the REAL
//  sources (not copies) — run with:
//    swiftc Tests/test_youtube_browser.swift \
//      lirik/Sources/NowPlaying/BrowserTabPoller.swift \
//      lirik/Sources/NowPlaying/NowPlayingTrack.swift \
//      lirik/Sources/Lyrics/LRCLIBClient.swift \
//      -o /tmp/yt_test && /tmp/yt_test
//
//  Browser live-polling itself (AppleScript tab enumeration, JS position
//  probe) is manual QA only per AGENTS.md §9 — it depends on running
//  browsers. Everything pure and testable is covered here.
//

import Foundation

@main
struct YouTubeBrowserTests {

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
        // ─── Group 1: splitArtistTitle ─────────────────────────────

        print("Group 1: BrowserTabPoller.splitArtistTitle")

        var r = BrowserTabPoller.splitArtistTitle(from: "Taylor Swift - Anti-Hero (Official Music Video) - YouTube")
        checkEqual(r.artist, "Taylor Swift", "artist split from standard upload title")
        checkEqual(r.title, "Anti-Hero (Official Music Video)", "title keeps parenthetical for cleanTrackTitle")

        r = BrowserTabPoller.splitArtistTitle(from: "Daft Punk - Around the World - YouTube Music")
        checkEqual(r.artist, "Daft Punk", "artist split with YouTube Music suffix")
        checkEqual(r.title, "Around the World", "title split with YouTube Music suffix")

        r = BrowserTabPoller.splitArtistTitle(from: "Never Gonna Give You Up - YouTube")
        checkEqual(r.artist, "Unknown Artist", "no separator falls back to Unknown Artist")
        checkEqual(r.title, "Never Gonna Give You Up", "full title kept when no artist separator")

        r = BrowserTabPoller.splitArtistTitle(from: "lofi hip hop radio - beats to relax/study to - YouTube")
        checkEqual(r.artist, "lofi hip hop radio", "livestream splits on first separator")
        checkEqual(r.title, "beats to relax/study to", "livestream title is remainder")

        r = BrowserTabPoller.splitArtistTitle(from: "  Artist  -  Title  - YouTube  ")
        checkEqual(r.artist, "Artist", "surrounding whitespace trimmed (artist)")
        checkEqual(r.title, "Title", "surrounding whitespace trimmed (title)")

        r = BrowserTabPoller.splitArtistTitle(from: " - YouTube")
        check(r.title.isEmpty, "empty after suffix strip yields empty title")

        // ─── Group 2: parsePositionOutput ──────────────────────────

        print("\nGroup 2: BrowserTabPoller.parsePositionOutput")

        if let p = BrowserTabPoller.parsePositionOutput("12.5|||213.0|||playing") {
            checkEqual(p.elapsed, 12.5, "elapsed parsed")
            checkEqual(p.duration, 213.0, "duration parsed")
            check(p.isPlaying, "playing state parsed")
        } else {
            check(false, "valid probe output parses")
        }

        if let p = BrowserTabPoller.parsePositionOutput("0|||0|||paused") {
            check(!p.isPlaying, "paused state parsed")
        } else {
            check(false, "paused probe output parses")
        }

        check(BrowserTabPoller.parsePositionOutput("") == nil, "empty output (no <video>) is nil")
        check(BrowserTabPoller.parsePositionOutput("garbage") == nil, "malformed output is nil")
        check(BrowserTabPoller.parsePositionOutput("12.5|||x|||playing") == nil, "non-numeric duration is nil")
        check(BrowserTabPoller.parsePositionOutput("12,5|||213,0|||playing") != nil, "decimal-comma output still parses")

        // ─── Group 3: cleanTrackTitle YouTube noise ────────────────

        print("\nGroup 3: LRCLIBClient.cleanTrackTitle (YouTube suffixes)")

        checkEqual(LRCLIBClient.cleanTrackTitle("Anti-Hero (Official Music Video)"), "Anti-Hero", "strips (Official Music Video)")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song [Official 4K Video]"), "Song", "strips [Official 4K Video]")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song - Official Video"), "Song", "strips - Official Video")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song [Official Audio]"), "Song", "strips [Official Audio]")
        checkEqual(LRCLIBClient.cleanTrackTitle("Blinding Lights (Official Lyric Video)"), "Blinding Lights", "strips (Official Lyric Video)")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song (M/V)"), "Song", "strips (M/V)")
        checkEqual(LRCLIBClient.cleanTrackTitle("Cruel Summer - Audio"), "Cruel Summer", "strips - Audio")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song (Visualizer)"), "Song", "strips (Visualizer)")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song (Remastered 2021)"), "Song", "existing remaster rule still works")
        checkEqual(LRCLIBClient.cleanTrackTitle("Midnight (feat. Artist B)"), "Midnight", "existing feat rule still works with YT title")
        checkEqual(LRCLIBClient.cleanTrackTitle("Ordinary Song Title"), "Ordinary Song Title", "clean title untouched")

        // ─── Group 4: source-aware track identity ──────────────────

        print("\nGroup 4: NowPlayingTrack.isSameTrack (source-aware)")

        let spotifyTrack = NowPlayingTrack(title: "Anti-Hero", artist: "Taylor Swift", album: nil, duration: 200, elapsedTime: 10, isPlaying: true, source: .spotify)
        let browserTrack = NowPlayingTrack(title: "Anti-Hero", artist: "Taylor Swift", album: nil, duration: 234, elapsedTime: 10, isPlaying: true, source: .browser)
        let spotifyLater = NowPlayingTrack(title: "Anti-Hero", artist: "Taylor Swift", album: nil, duration: 200, elapsedTime: 90, isPlaying: true, source: .spotify)
        let otherSong = NowPlayingTrack(title: "Shake It Off", artist: "Taylor Swift", album: nil, duration: 200, elapsedTime: 0, isPlaying: true, source: .spotify)

        check(!spotifyTrack.isSameTrack(as: browserTrack), "same song on Spotify vs YouTube counts as track change")
        check(spotifyTrack.isSameTrack(as: spotifyLater), "elapsed-time update on same source is not a change")
        check(!spotifyTrack.isSameTrack(as: otherSong), "different song is a change")

        print("\n══════════════════════════════════════════════════════")
        print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
        print("══════════════════════════════════════════════════════")

        if failCount > 0 {
            exit(1)
        }
    }
}
