//
//  test_youtube_captions.swift
//  lirik
//
//  Unit tests for the YouTube closed-caption lyrics fallback. Compiles
//  against the REAL sources (not copies) — run with:
//    swiftc Tests/test_youtube_captions.swift \
//      lirik/Sources/Lyrics/YouTubeCaptionsClient.swift \
//      lirik/Sources/Lyrics/LRCParser.swift \
//      -o /tmp/cap_test && /tmp/cap_test
//
//  The in-page capture sequence (AppleScript round-trips, CC cycling) is
//  manual QA only per AGENTS.md §9 — it depends on a live browser tab.
//  Everything pure (track ranking, json3 parsing, cleaning, videoId
//  extraction) is covered here. videoId extraction lives in
//  test_youtube_browser.swift alongside the poller.
//

import Foundation

@main
struct YouTubeCaptionsTests {

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

    static let fixtureJSON3 = """
    {"events":[
     {"tStartMs":1000,"dDurationMs":2000,"segs":[{"utf8":"It starts with one\\n"}]},
     {"tStartMs":3000,"dDurationMs":1500,"segs":[{"utf8":"[Music]"}]},
     {"tStartMs":5000,"dDurationMs":2000,"segs":[{"utf8":">> One thing I don't know why"}]},
     {"tStartMs":8000,"dDurationMs":2000,"segs":[{"utf8":"MIKE: Keep that in mind"}]},
     {"tStartMs":11000,"dDurationMs":1800,"segs":[{"utf8":"(ooh) I tried so hard"}]},
     {"tStartMs":14000,"segs":[{"utf8":"   "}]},
     {"dDurationMs":1000,"segs":[{"utf8":"no timestamp"}]},
     {"tStartMs":17000,"dDurationMs":1000,"segs":[]}
    ]}
    """

    static func main() async {
        // ─── Group 1: chooseTrack ──────────────────────────────────

        print("Group 1: YouTubeCaptionsClient.chooseTrack")

        let manualEN = CaptionTrackOption(languageCode: "en", kind: nil)
        let autoEN = CaptionTrackOption(languageCode: "en", kind: "asr")
        let manualID = CaptionTrackOption(languageCode: "id", kind: nil)
        let autoID = CaptionTrackOption(languageCode: "id", kind: "asr")

        checkEqual(YouTubeCaptionsClient.chooseTrack(from: [autoID, manualID, autoEN, manualEN]), manualEN, "manual English wins")
        checkEqual(YouTubeCaptionsClient.chooseTrack(from: [autoID, manualID, autoEN]), autoEN, "auto English beats manual other")
        checkEqual(YouTubeCaptionsClient.chooseTrack(from: [autoID, manualID]), manualID, "manual other beats auto other")
        checkEqual(YouTubeCaptionsClient.chooseTrack(from: [autoID]), autoID, "lone auto track returned")
        check(YouTubeCaptionsClient.chooseTrack(from: []) == nil, "no tracks returns nil")
        checkEqual(
            YouTubeCaptionsClient.chooseTrack(from: [CaptionTrackOption(languageCode: "EN", kind: nil)]),
            CaptionTrackOption(languageCode: "EN", kind: nil),
            "language match is case-insensitive"
        )

        // ─── Group 2: parseJSON3 ───────────────────────────────────

        print("\nGroup 2: YouTubeCaptionsClient.parseJSON3")

        if let lines = YouTubeCaptionsClient.parseJSON3(fixtureJSON3) {
            checkEqual(lines.count, 4, "keeps 4 lyric lines, drops noise")
            checkEqual(lines[0], LRCLine(timestamp: 1.0, text: "It starts with one"), "first line text + timestamp")
            checkEqual(lines[1].text, "One thing I don't know why", "strips >> continuation marker")
            checkEqual(lines[2].text, "Keep that in mind", "strips NAME: speaker prefix")
            checkEqual(lines[3].text, "(ooh) I tried so hard", "keeps parenthesized backing vocals")
        } else {
            check(false, "fixture parses to lines")
        }

        check(YouTubeCaptionsClient.parseJSON3("not json") == nil, "malformed body is nil")
        check(YouTubeCaptionsClient.parseJSON3(#"{"events":[]}"#) == nil, "empty events is nil")
        check(YouTubeCaptionsClient.parseJSON3(#"{"events":[{"tStartMs":1000,"segs":[{"utf8":"[Music]"}]}]}"#) == nil, "music-only body is nil")

        // ─── Group 3: cleanCaptionText ─────────────────────────────

        print("\nGroup 3: YouTubeCaptionsClient.cleanCaptionText")

        checkEqual(YouTubeCaptionsClient.cleanCaptionText("[Applause]"), nil, "drops bracket-only annotation")
        checkEqual(YouTubeCaptionsClient.cleanCaptionText("   "), nil, "drops whitespace-only")
        checkEqual(YouTubeCaptionsClient.cleanCaptionText("Hello: world"), "Hello: world", "keeps mixed-case colon text")
        checkEqual(YouTubeCaptionsClient.cleanCaptionText("02:15"), "02:15", "keeps numeric timestamps in text")
        checkEqual(YouTubeCaptionsClient.cleanCaptionText("line one\nline two"), "line one line two", "joins embedded newlines")

        // ─── Group 4: makeLRC ──────────────────────────────────────

        print("\nGroup 4: YouTubeCaptionsClient.makeLRC")

        checkEqual(
            YouTubeCaptionsClient.makeLRC(from: [LRCLine(timestamp: 65.5, text: "hi")]),
            "[01:05.50]hi",
            "formats LRC timestamp"
        )

        // ─── Group 5: fetchLyrics with stubbed capture ─────────────

        print("\nGroup 5: YouTubeCaptionsClient.fetchLyrics (stubbed page layer)")

        let stubClient = YouTubeCaptionsClient(fetchCaptionJSON: { _ in fixtureJSON3 })
        if let result = await stubClient.fetchLyrics(videoId: "abc123") {
            checkEqual(result.lines.count, 4, "stubbed capture yields parsed lines")
            check(result.rawLRC.contains("[00:01.00]It starts with one"), "rawLRC embeds LRC line")
        } else {
            check(false, "stubbed capture resolves lyrics")
        }

        let emptyClient = YouTubeCaptionsClient(fetchCaptionJSON: { _ in nil })
        check(await emptyClient.fetchLyrics(videoId: "abc123") == nil, "nil capture body is nil")

        let garbageClient = YouTubeCaptionsClient(fetchCaptionJSON: { _ in "nope" })
        check(await garbageClient.fetchLyrics(videoId: "abc123") == nil, "unparsable body is nil")

        // ─── Group 6: calibrationOffset ────────────────────────────

        print("\nGroup 6: YouTubeCaptionsClient.calibrationOffset")

        let albumLines = [
            LRCLine(timestamp: 0.24, text: "Here we go"),
            LRCLine(timestamp: 2.84, text: "Come with me"),
        ]
        // Music video opens with a ~20s dialogue intro: same words, later.
        let videoCaptions = [
            LRCLine(timestamp: 21.0, text: "Here we go"),
            LRCLine(timestamp: 23.5, text: "Come with me"),
        ]
        if let offset = YouTubeCaptionsClient.calibrationOffset(lrclib: albumLines, captions: videoCaptions) {
            check(abs(offset - 20.76) < 0.01, "finds +20.76s MV intro offset (got: \(offset))")
        } else {
            check(false, "finds MV intro offset")
        }

        check(
            YouTubeCaptionsClient.calibrationOffset(
                lrclib: albumLines,
                captions: [LRCLine(timestamp: 0.3, text: "Here we go")]
            ) == nil,
            "negligible shift is nil (no-op)"
        )
        check(
            YouTubeCaptionsClient.calibrationOffset(
                lrclib: albumLines,
                captions: [LRCLine(timestamp: 200.0, text: "Here we go")]
            ) == nil,
            "implausible shift is nil"
        )
        check(
            YouTubeCaptionsClient.calibrationOffset(
                lrclib: albumLines,
                captions: [LRCLine(timestamp: 21.0, text: "Completely different words")]
            ) == nil,
            "mismatched first lines are nil (wrong-video guard)"
        )
        check(
            YouTubeCaptionsClient.calibrationOffset(lrclib: [], captions: videoCaptions) == nil,
            "empty LRC is nil"
        )
        check(
            YouTubeCaptionsClient.calibrationOffset(
                lrclib: [LRCLine(timestamp: 0.24, text: "Here we GO!")],
                captions: [LRCLine(timestamp: 21.0, text: "here we go")]
            ) != nil,
            "match ignores case and punctuation"
        )

        print("\n══════════════════════════════════════════════════════")
        print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
        print("══════════════════════════════════════════════════════")

        if failCount > 0 {
            exit(1)
        }
    }
}
