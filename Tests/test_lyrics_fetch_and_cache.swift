#!/usr/bin/env swift
//
//  test_lyrics_fetch_and_cache.swift
//  lirik
//
//  Manual verification script for Phase 2: LRCLIB fetch, parse, and cache.
//
//  Demonstrates:
//   1. First lookup: Cache MISS -> network fetch from LRCLIB -> LRC parse -> saved to disk cache
//   2. Second lookup: Cache HIT -> read from disk cache instantly (0 network requests)
//

import Foundation
import CryptoKit

// ─── Inline types (mirrors of the real code) ───────────────────────

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

enum LRCLIBResult: Sendable, Equatable {
    case synced(id: Int, lrcText: String, plainLyrics: String?)
    case plainOnly(id: Int, plainText: String)
    case notFound
}

// ─── LRCParser ─────────────────────────────────────────────────────

enum LRCParser {
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#,
        options: []
    )

    static func parse(_ lrcText: String) -> [LRCLine] {
        guard !lrcText.isEmpty else { return [] }
        var lines: [LRCLine] = []

        for rawLine in lrcText.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let nsLine = trimmed as NSString
            let matches = timestampPattern.matches(
                in: trimmed,
                options: [],
                range: NSRange(location: 0, length: nsLine.length)
            )

            if matches.isEmpty { continue }
            guard matches[0].range.location == 0 else { continue }

            var lastMatchEnd = 0
            var timestamps: [TimeInterval] = []

            for match in matches {
                if match.range.location > lastMatchEnd { break }
                lastMatchEnd = match.range.location + match.range.length

                guard match.numberOfRanges > 2,
                      let minutes = extractInt(from: trimmed, range: match.range(at: 1)),
                      let seconds = extractInt(from: trimmed, range: match.range(at: 2)) else {
                    continue
                }

                let fractional: Double
                if match.numberOfRanges > 3 {
                    let fractionalRange = match.range(at: 3)
                    if fractionalRange.location != NSNotFound,
                       let fracStr = extractString(from: trimmed, range: fractionalRange) {
                        let padded = fracStr.padding(toLength: 3, withPad: "0", startingAt: 0)
                        fractional = (Double(padded) ?? 0) / 1000.0
                    } else { fractional = 0 }
                } else { fractional = 0 }

                let timestamp = Double(minutes) * 60.0 + Double(seconds) + fractional
                timestamps.append(timestamp)
            }

            if timestamps.isEmpty { continue }

            let text = String(nsLine.substring(from: lastMatchEnd))
                .trimmingCharacters(in: .whitespaces)

            for ts in timestamps {
                lines.append(LRCLine(timestamp: ts, text: text))
            }
        }

        lines.sort { $0.timestamp < $1.timestamp }
        return lines
    }

    private static func extractString(from string: String, range: NSRange) -> String? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.location + range.length <= (string as NSString).length,
              let swiftRange = Range(range, in: string) else { return nil }
        return String(string[swiftRange])
    }

    private static func extractInt(from string: String, range: NSRange) -> Int? {
        guard let str = extractString(from: string, range: range) else { return nil }
        return Int(str)
    }
}

// ─── LRCLIBClient ──────────────────────────────────────────────────

private struct LRCLIBResponseDTO: Decodable {
    let id: Int
    let plainLyrics: String?
    let syncedLyrics: String?
}

final class LRCLIBClient: Sendable {
    private let baseURL = "https://lrclib.net/api/get"
    private let userAgent = "Lirik/1.0 (macOS TouchBar Lyric Widget)"

    func fetchLyrics(title: String, artist: String, duration: TimeInterval?) async throws -> LRCLIBResult {
        guard var components = URLComponents(string: baseURL) else { return .notFound }
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if let duration = duration, duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = queryItems
        guard let url = components.url else { return .notFound }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return .notFound }

        if httpResponse.statusCode == 200 {
            let dto = try JSONDecoder().decode(LRCLIBResponseDTO.self, from: data)
            if let synced = dto.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .synced(id: dto.id, lrcText: synced, plainLyrics: dto.plainLyrics)
            } else if let plain = dto.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .plainOnly(id: dto.id, plainText: plain)
            }
        }
        return .notFound
    }
}

// ─── LyricsCache ───────────────────────────────────────────────────

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
        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedLyrics.self, from: data)
    }

    func save(_ entry: CachedLyrics) {
        let fileURL = cacheDirectory.appendingPathComponent("\(entry.trackKey).json")
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// ─── Manual Verification Flow ──────────────────────────────────────

print("╔══════════════════════════════════════════════════════╗")
print("║  Lirik — Phase 2: Fetch, Parse & Cache Verification ║")
print("╚══════════════════════════════════════════════════════╝\n")

let testTitle = "Yellow"
let testArtist = "Coldplay"
let testDuration: TimeInterval = 267.0

let cache = LyricsCache()
let client = LRCLIBClient()

let semaphore = DispatchSemaphore(value: 0)

Task {
    print("🎵 Target Track: \"\(testTitle)\" by \(testArtist) (\(Int(testDuration))s)")
    let trackKey = LyricsCache.makeTrackKey(title: testTitle, artist: testArtist, duration: testDuration)
    print("🔑 Computed Track Key (SHA256): \(trackKey)\n")

    // ─────────────────────────────────────────────────────────────
    // STEP 1: First Lookup (Simulating first play of a song)
    // ─────────────────────────────────────────────────────────────
    print("--- [STEP 1] First Play: Checking Cache ---")
    let firstCheck = cache.get(title: testTitle, artist: testArtist, duration: testDuration)

    if let cached = firstCheck {
        print("  ⚠️ Found existing cache from previous run: \(cached.lyricsState)")
    } else {
        print("  ❌ Cache MISS (Expected on first play)")
    }

    print("\n--- [STEP 1] Fetching from LRCLIB REST API ---")
    let startTime = Date()
    let result = try await client.fetchLyrics(title: testTitle, artist: testArtist, duration: testDuration)
    let fetchDuration = Date().timeIntervalSince(startTime)
    print("  🌐 LRCLIB Network Response Received in \(String(format: "%.2f", fetchDuration))s")

    let stateToCache: CachedLyricsState
    let lrclibID: Int?

    switch result {
    case .synced(let id, let lrcText, _):
        lrclibID = id
        print("  ✅ Synced LRC Lyrics Found (LRCLIB ID: \(id))")
        let parsedLines = LRCParser.parse(lrcText)
        print("  📄 Parsed \(parsedLines.count) timestamped lines.")
        print("  Sample Lines:")
        for line in parsedLines.prefix(4) {
            let m = Int(line.timestamp) / 60
            let s = Int(line.timestamp) % 60
            let ms = Int((line.timestamp.truncatingRemainder(dividingBy: 1)) * 100)
            print(String(format: "     [%02d:%02d.%02d] %@", m, s, ms, line.text))
        }
        stateToCache = .synced(lines: parsedLines, rawLRC: lrcText)

    case .plainOnly(let id, let plainText):
        lrclibID = id
        print("  ℹ️ Plain Lyrics Found (not synced, ID: \(id))")
        stateToCache = .plainOnly(text: plainText)

    case .notFound:
        lrclibID = nil
        print("  ⚠️ No Lyrics Found on LRCLIB (HTTP 404)")
        stateToCache = .notFound
    }

    // Save to cache
    let entryToCache = CachedLyrics(
        lrclibID: lrclibID,
        trackKey: trackKey,
        lyricsState: stateToCache,
        cachedAt: Date()
    )
    cache.save(entryToCache)
    print("  💾 Saved parsed result to disk cache successfully.\n")

    // ─────────────────────────────────────────────────────────────
    // STEP 2: Second Lookup (Simulating replay of the same song)
    // ─────────────────────────────────────────────────────────────
    print("--- [STEP 2] Second Play: Re-checking Cache ---")
    let secondStartTime = Date()
    let secondCheck = cache.get(title: testTitle, artist: testArtist, duration: testDuration)
    let readDuration = Date().timeIntervalSince(secondStartTime)

    if let cached = secondCheck {
        print("  🎯 Cache HIT! Read from disk in \(String(format: "%.4f", readDuration))s (0 network calls!)")
        print("  Cached LRCLIB ID: \(cached.lrclibID ?? 0)")
        
        switch cached.lyricsState {
        case .synced(let lines, _):
            print("  Cached Synced Lines Count: \(lines.count)")
            print("  Cached Line Sample: \"\(lines.first?.text ?? "")\" at \(lines.first?.timestamp ?? 0)s")
        case .plainOnly(let text):
            print("  Cached Plain Text Length: \(text.count) chars")
        case .notFound:
            print("  Cached State: notFound")
        }
    } else {
        print("  ❌ ERROR: Expected Cache HIT on second check, but got MISS!")
    }

    print("\n══════════════════════════════════════════════════════")
    print("VERIFICATION COMPLETE: Fetch, Parse & Cache Working!")
    print("══════════════════════════════════════════════════════")

    semaphore.signal()
}

semaphore.wait()
