//
//  LyricsCacheTests.swift
//  lirik
//
//  Unit tests for LyricsCache per AGENTS.md §9.
//  Covers:
//  - Track key generation & normalization
//  - Cache save & read round-trip
//  - Not-found state caching
//  - Eviction / clear behavior
//

import XCTest
#if canImport(Foundation)
import Foundation
#endif

final class LyricsCacheTests: XCTestCase {

    var tempDirectory: URL!
    var cache: LyricsCache!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsCacheTests_\(UUID().uuidString)")
        cache = LyricsCache(directoryURL: tempDirectory)
    }

    override func tearDown() {
        cache.clear()
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testTrackKeyDeterministic() {
        let key1 = LyricsCache.makeTrackKey(title: "Yellow", artist: "Coldplay", duration: 267.0)
        let key2 = LyricsCache.makeTrackKey(title: "yellow ", artist: " COLDPLAY", duration: 267.4)
        XCTAssertEqual(key1, key2, "Normalized metadata should produce identical track key")
    }

    func testSaveAndReadRoundTrip() {
        let title = "Yellow"
        let artist = "Coldplay"
        let duration = 267.0
        let key = LyricsCache.makeTrackKey(title: title, artist: artist, duration: duration)

        let lines = [LRCLine(timestamp: 35.66, text: "Look at the stars")]
        let entry = CachedLyrics(
            lrclibID: 16232,
            trackKey: key,
            lyricsState: .synced(lines: lines, rawLRC: "[00:35.66] Look at the stars"),
            cachedAt: Date()
        )

        cache.save(entry)

        let retrieved = cache.get(title: title, artist: artist, duration: duration)
        XCTAssertNotNil(retrieved, "Cached entry should be retrievable")
        XCTAssertEqual(retrieved?.lrclibID, 16232)
        XCTAssertEqual(retrieved?.lyricsState, entry.lyricsState)
    }

    func testNotFoundCaching() {
        let key = LyricsCache.makeTrackKey(title: "Nonexistent", artist: "Nobody")
        let entry = CachedLyrics(
            lrclibID: nil,
            trackKey: key,
            lyricsState: .notFound,
            cachedAt: Date()
        )

        cache.save(entry)

        let retrieved = cache.get(title: "Nonexistent", artist: "Nobody")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.lyricsState, .notFound)
    }

    func testCacheClear() {
        let key = LyricsCache.makeTrackKey(title: "Song", artist: "Artist")
        let entry = CachedLyrics(
            lrclibID: 100,
            trackKey: key,
            lyricsState: .plainOnly(text: "Plain text"),
            cachedAt: Date()
        )

        cache.save(entry)
        XCTAssertNotNil(cache.get(title: "Song", artist: "Artist"))

        cache.clear()
        XCTAssertNil(cache.get(title: "Song", artist: "Artist"), "Cache should be empty after clear")
    }
}
