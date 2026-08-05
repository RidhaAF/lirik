#!/usr/bin/env swift
//
//  run_lyrics_cache_tests.swift
//  lirik
//
//  Command-line runner for LyricsCacheTests.
//

import Foundation
import CryptoKit

struct LRCLine: Equatable, Sendable, Codable {
    let timestamp: TimeInterval
    let text: String
}

enum CachedLyricsState: Codable, Sendable, Equatable {
    case synced(lines: [LRCLine], rawLRC: String)
    case plainOnly(text: String)
    case notFound
}

struct CachedLyrics: Codable, Sendable, Equatable {
    let lrclibID: Int?
    let trackKey: String
    let lyricsState: CachedLyricsState
    let cachedAt: Date
}

final class LyricsCache {
    private let cacheDirectory: URL

    init(directoryURL: URL? = nil) {
        if let customURL = directoryURL {
            self.cacheDirectory = customURL
        } else {
            let userCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheDirectory = userCaches
                .appendingPathComponent("io.github.ridhaaf.lirik", isDirectory: true)
                .appendingPathComponent("lyrics", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    static func makeTrackKey(title: String, artist: String, duration: TimeInterval? = nil) -> String {
        let normTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let durSec = duration != nil && duration! > 0 ? String(Int(duration!.rounded())) : "0"
        let signature = "\(normArtist)|\(normTitle)|\(durSec)"
        let digest = SHA256.hash(data: Data(signature.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    func get(title: String, artist: String, duration: TimeInterval? = nil) -> CachedLyrics? {
        let key = Self.makeTrackKey(title: title, artist: artist, duration: duration)
        return get(byKey: key)
    }

    func get(byKey key: String) -> CachedLyrics? {
        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedLyrics.self, from: data)
    }

    func save(_ entry: CachedLyrics) {
        let fileURL = cacheDirectory.appendingPathComponent("\(entry.trackKey).json")
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

// ─── Test Runner ───────────────────────────────────────────────────

var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ message: String) {
    if condition {
        passCount += 1
        print("  ✅ \(message)")
    } else {
        failCount += 1
        print("  ❌ FAIL: \(message)")
    }
}

print("╔══════════════════════════════════════════════════════╗")
print("║         LyricsCache Unit Test Suite                 ║")
print("╚══════════════════════════════════════════════════════╝\n")

let tempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("LyricsCacheTest_\(UUID().uuidString)")
let cache = LyricsCache(directoryURL: tempDirectory)

print("Test Group 1: Deterministic Track Key Generation")
let key1 = LyricsCache.makeTrackKey(title: "Yellow", artist: "Coldplay", duration: 267.0)
let key2 = LyricsCache.makeTrackKey(title: "yellow ", artist: " COLDPLAY", duration: 267.4)
assert(key1 == key2, "Normalized title/artist/duration generate identical SHA256 key")

print("\nTest Group 2: Save and Read Synced Lyrics Round-Trip")
let lines = [LRCLine(timestamp: 35.66, text: "Look at the stars")]
let entry = CachedLyrics(
    lrclibID: 16232,
    trackKey: key1,
    lyricsState: .synced(lines: lines, rawLRC: "[00:35.66] Look at the stars"),
    cachedAt: Date()
)
cache.save(entry)

let retrieved = cache.get(title: "Yellow", artist: "Coldplay", duration: 267.0)
assert(retrieved != nil, "Retrieved entry from disk")
assert(retrieved?.lrclibID == 16232, "LRCLIB ID matches")
assert(retrieved?.lyricsState == entry.lyricsState, "Lyrics state matches")

print("\nTest Group 3: Caching NotFound State")
let keyNotFound = LyricsCache.makeTrackKey(title: "Nonexistent", artist: "Nobody")
let notFoundEntry = CachedLyrics(
    lrclibID: nil,
    trackKey: keyNotFound,
    lyricsState: .notFound,
    cachedAt: Date()
)
cache.save(notFoundEntry)

let retrievedNotFound = cache.get(title: "Nonexistent", artist: "Nobody")
assert(retrievedNotFound != nil, "Retrieved notFound entry")
assert(retrievedNotFound?.lyricsState == .notFound, "Lyrics state is explicitly notFound")

print("\nTest Group 4: Cache Clear")
cache.clear()
let retrievedAfterClear = cache.get(title: "Yellow", artist: "Coldplay", duration: 267.0)
assert(retrievedAfterClear == nil, "Cache is empty after clear()")

try? FileManager.default.removeItem(at: tempDirectory)

print("\n══════════════════════════════════════════════════════")
print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
print("══════════════════════════════════════════════════════")

if failCount > 0 {
    exit(1)
} else {
    exit(0)
}
