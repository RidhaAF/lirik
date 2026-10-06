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

/// URLProtocol stub that replays canned responses so the LRCLIB retry
/// chain can be tested without network access.
final class StubURLProtocol: URLProtocol {
    static var responses: [(status: Int, json: String)] = []
    static var recordedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.recordedURLs.append(url)
        let index = min(Self.recordedURLs.count - 1, Self.responses.count - 1)
        let stub = Self.responses[index]
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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

    static func main() async {
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
            check(!p.muted, "missing muted segment means sound")
        } else {
            check(false, "valid probe output parses")
        }

        if let p = BrowserTabPoller.parsePositionOutput("12.5|||213.0|||playing|||muted") {
            check(p.isPlaying && p.muted, "muted flag parsed")
        } else {
            check(false, "muted probe output parses")
        }

        if let p = BrowserTabPoller.parsePositionOutput("12.5|||213.0|||playing|||sound") {
            check(p.isPlaying && !p.muted, "sound flag parsed as unmuted")
        } else {
            check(false, "sound probe output parses")
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
        checkEqual(LRCLIBClient.cleanTrackTitle("Waiting For The End (Official Music Video) [4K Upgrade]"), "Waiting For The End", "strips combined official + 4K noise")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song (4K Remaster)"), "Song", "strips (4K Remaster)")
        checkEqual(LRCLIBClient.cleanTrackTitle("Song [HD]"), "Song", "strips [HD]")
        checkEqual(LRCLIBClient.cleanTrackTitle("In The End [Live in São Paulo] (Official Video)"), "In The End", "strips bracketed live tag + official video")

        // ─── Group 4: source-aware track identity ──────────────────

        print("\nGroup 4: NowPlayingTrack.isSameTrack (source-aware)")

        let spotifyTrack = NowPlayingTrack(title: "Anti-Hero", artist: "Taylor Swift", album: nil, duration: 200, elapsedTime: 10, isPlaying: true, source: .spotify, videoId: nil)
        let browserTrack = NowPlayingTrack(title: "Anti-Hero", artist: "Taylor Swift", album: nil, duration: 234, elapsedTime: 10, isPlaying: true, source: .browser, videoId: "dQw4w9WgXcQ")
        let spotifyLater = NowPlayingTrack(title: "Anti-Hero", artist: "Taylor Swift", album: nil, duration: 200, elapsedTime: 90, isPlaying: true, source: .spotify, videoId: nil)
        let otherSong = NowPlayingTrack(title: "Shake It Off", artist: "Taylor Swift", album: nil, duration: 200, elapsedTime: 0, isPlaying: true, source: .spotify, videoId: nil)
        let ytmTrack = NowPlayingTrack(title: "Anti-Hero", artist: "Taylor Swift", album: "Midnights", duration: 200, elapsedTime: 10, isPlaying: true, source: .youTubeMusic, videoId: "dQw4w9WgXcQ")

        check(!spotifyTrack.isSameTrack(as: browserTrack), "same song on Spotify vs YouTube counts as track change")
        check(spotifyTrack.isSameTrack(as: spotifyLater), "elapsed-time update on same source is not a change")
        check(!spotifyTrack.isSameTrack(as: otherSong), "different song is a change")
        check(!browserTrack.isSameTrack(as: ytmTrack), "YouTube vs YouTube Music counts as track change")

        // ─── Group 5: swapped artist/title retry ───────────────────

        print("\nGroup 5: LRCLIBClient swapped retry (Title - Artist uploads)")

        // Simulates what BrowserTabPoller produces for a "Title - Artist"
        // upload like "Waiting For The End (…) - Linkin Park": the split
        // yields a backwards pair, so the first lookup 404s and the client
        // must retry with the fields swapped.
        StubURLProtocol.recordedURLs = []
        StubURLProtocol.responses = [
            (404, ""),
            (200, #"{"id": 42, "trackName": "Waiting For The End", "artistName": "Linkin Park", "syncedLyrics": "[00:01.00] first line\n", "plainLyrics": "first line\n"}"#),
        ]
        let stubConfig = URLSessionConfiguration.ephemeral
        stubConfig.protocolClasses = [StubURLProtocol.self]
        let stubClient = LRCLIBClient(session: URLSession(configuration: stubConfig))

        do {
            let result = try await stubClient.fetchLyrics(
                title: "Linkin Park",
                artist: "Waiting For The End (Official Music Video) [4K Upgrade]"
            )
            check(result == .synced(id: 42, lrcText: "[00:01.00] first line\n", plainLyrics: "first line\n"), "swapped retry resolves synced lyrics")
            checkEqual(StubURLProtocol.recordedURLs.count, 2, "exactly two requests (initial + swapped; clean title needs no sanitize retry)")

            let queryItems = StubURLProtocol.recordedURLs.map { url in
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            }
            let firstTrack = queryItems[0].first(where: { $0.name == "track_name" })?.value
            let secondTrack = queryItems[1].first(where: { $0.name == "track_name" })?.value
            let secondArtist = queryItems[1].first(where: { $0.name == "artist_name" })?.value
            checkEqual(firstTrack, "Linkin Park", "first request uses split order")
            checkEqual(secondTrack, "Waiting For The End", "retry swaps in cleaned video title")
            checkEqual(secondArtist, "Linkin Park", "retry swaps in artist")
        } catch {
            check(false, "swapped retry does not throw (threw: \(error))")
        }

        // Unknown Artist must not trigger a swap retry (nothing to swap with).
        StubURLProtocol.recordedURLs = []
        StubURLProtocol.responses = [(404, "")]
        do {
            let result = try await stubClient.fetchLyrics(title: "Never Gonna Give You Up", artist: "Unknown Artist")
            check(result == .notFound, "unknown-artist miss stays notFound")
            checkEqual(StubURLProtocol.recordedURLs.count, 1, "no swap retry for Unknown Artist")
        } catch {
            check(false, "unknown-artist lookup does not throw (threw: \(error))")
        }

        // ─── Group 6: selectBest audible ranking ───────────────────

        print("\nGroup 6: BrowserTabPoller.selectBest (audible ranking)")

        func makeBrowserTrack(title: String, playing: Bool) -> NowPlayingTrack {
            NowPlayingTrack(title: title, artist: "A", album: nil, duration: nil, elapsedTime: nil, isPlaying: playing, source: .browser, videoId: nil)
        }

        let mutedPlaying = (track: makeBrowserTrack(title: "Muted", playing: true), audible: false as Bool?)
        let unknownPlaying = (track: makeBrowserTrack(title: "Unknown", playing: true), audible: nil as Bool?)
        let audiblePlaying = (track: makeBrowserTrack(title: "Audible", playing: true), audible: true as Bool?)
        let paused = (track: makeBrowserTrack(title: "Paused", playing: false), audible: false as Bool?)

        checkEqual(BrowserTabPoller.selectBest(from: [mutedPlaying, unknownPlaying, audiblePlaying])?.title, "Audible", "audible playing beats muted/unknown playing")
        checkEqual(BrowserTabPoller.selectBest(from: [mutedPlaying, unknownPlaying])?.title, "Unknown", "unknown-audible playing beats muted playing")
        checkEqual(BrowserTabPoller.selectBest(from: [mutedPlaying, paused])?.title, "Muted", "muted playing still beats paused")
        checkEqual(BrowserTabPoller.selectBest(from: [paused])?.title, "Paused", "lone paused tab returned as fallback")
        check(BrowserTabPoller.selectBest(from: []) == nil, "no candidates returns nil")
        checkEqual(
            BrowserTabPoller.selectBest(from: [
                (track: makeBrowserTrack(title: "First", playing: true), audible: nil as Bool?),
                (track: makeBrowserTrack(title: "Second", playing: true), audible: nil as Bool?),
            ])?.title, "First", "ties keep poll order")

        // ─── Group 7: extractVideoId ───────────────────────────────

        print("\nGroup 7: BrowserTabPoller.extractVideoId")

        checkEqual(BrowserTabPoller.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ", "watch URL")
        checkEqual(BrowserTabPoller.extractVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDxyz&start_radio=1"), "dQw4w9WgXcQ", "watch URL with playlist params")
        checkEqual(BrowserTabPoller.extractVideoId(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ", "short share URL")
        checkEqual(BrowserTabPoller.extractVideoId(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ", "Shorts URL")
        checkEqual(BrowserTabPoller.extractVideoId(from: "https://www.youtube.com/live/dQw4w9WgXcQ"), "dQw4w9WgXcQ", "live URL")
        checkEqual(BrowserTabPoller.extractVideoId(from: "https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ", "embed URL")
        checkEqual(BrowserTabPoller.extractVideoId(from: "https://music.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ", "YouTube Music URL")
        check(BrowserTabPoller.extractVideoId(from: "https://www.youtube.com/") == nil, "home page has no ID")
        check(BrowserTabPoller.extractVideoId(from: "https://www.youtube.com/@LinkinPark") == nil, "channel page has no ID")
        check(BrowserTabPoller.extractVideoId(from: "not a url") == nil, "garbage has no ID")

        // ─── Group 8: resolveMetadata (Media Session) ──────────────

        print("\nGroup 8: BrowserTabPoller.resolveMetadata")

        let ytm = BrowserTabPoller.MediaSessionMetadata(title: "L’AMOUR DE MA VIE", artist: "Billie Eilish", album: "HIT ME HARD AND SOFT")
        let resolved = BrowserTabPoller.resolveMetadata(tabTitle: "YouTube Music", mediaSession: ytm, isMusic: true)
        checkEqual(resolved.title, "L’AMOUR DE MA VIE", "YTM prefers Media Session title over generic tab title")
        checkEqual(resolved.artist, "Billie Eilish", "YTM prefers Media Session artist")
        checkEqual(resolved.album, "HIT ME HARD AND SOFT", "YTM surfaces the album")

        let noMS = BrowserTabPoller.resolveMetadata(tabTitle: "Taylor Swift - Anti-Hero - YouTube Music", mediaSession: nil, isMusic: true)
        checkEqual(noMS.title, "Anti-Hero", "YTM without Media Session falls back to title split")
        checkEqual(noMS.artist, "Taylor Swift", "YTM fallback keeps split artist")

        let emptyMS = BrowserTabPoller.MediaSessionMetadata(title: "  ", artist: "", album: "")
        let emptyResolved = BrowserTabPoller.resolveMetadata(tabTitle: "Daft Punk - Around the World - YouTube", mediaSession: emptyMS, isMusic: true)
        checkEqual(emptyResolved.title, "Around the World", "blank Media Session falls back to split")

        // Plain YouTube ignores Media Session (artist would be the channel).
        let channelMS = BrowserTabPoller.MediaSessionMetadata(title: "Waiting For The End (Official Music Video)", artist: "Linkin Park", album: "")
        let plainResolved = BrowserTabPoller.resolveMetadata(tabTitle: "Linkin Park - Waiting For The End - YouTube", mediaSession: channelMS, isMusic: false)
        checkEqual(plainResolved.title, "Waiting For The End", "plain YouTube keeps tab-title split")
        check(plainResolved.album == nil, "plain YouTube reports no album")

        print("\n══════════════════════════════════════════════════════")
        print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
        print("══════════════════════════════════════════════════════")

        if failCount > 0 {
            exit(1)
        }
    }
}
