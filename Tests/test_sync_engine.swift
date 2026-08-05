#!/usr/bin/env swift
//
//  test_sync_engine.swift
//  lirik
//
//  Manual verification script for Phase 3: LRCSyncEngine live seek detection.
//

import Foundation
import AppKit
import CryptoKit

// ─── Inline types (mirrors of the real code) ───────────────────────

struct LRCLine: Equatable, Sendable, Codable {
    let timestamp: TimeInterval
    let text: String
}

enum LRCPositionState: Equatable, Sendable {
    case empty
    case beforeFirstLine
    case inLyrics
    case afterLastLine
}

struct LRCSyncSnapshot: Equatable, Sendable {
    let currentLine: LRCLine?
    let currentIndex: Int?
    let upcomingLine: LRCLine?
    let upcomingIndex: Int?
    let positionState: LRCPositionState
}

enum LRCSyncEngine {
    static func resolve(elapsedTime: TimeInterval, lines: [LRCLine]) -> LRCSyncSnapshot {
        guard !lines.isEmpty else {
            return LRCSyncSnapshot(
                currentLine: nil,
                currentIndex: nil,
                upcomingLine: nil,
                upcomingIndex: nil,
                positionState: .empty
            )
        }

        if elapsedTime < lines[0].timestamp {
            return LRCSyncSnapshot(
                currentLine: nil,
                currentIndex: nil,
                upcomingLine: lines[0],
                upcomingIndex: 0,
                positionState: .beforeFirstLine
            )
        }

        if elapsedTime >= lines.last!.timestamp {
            let lastIdx = lines.count - 1
            return LRCSyncSnapshot(
                currentLine: lines[lastIdx],
                currentIndex: lastIdx,
                upcomingLine: nil,
                upcomingIndex: nil,
                positionState: .afterLastLine
            )
        }

        var low = 0
        var high = lines.count - 1
        var matchIndex = 0

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timestamp <= elapsedTime {
                matchIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let nextIndex = matchIndex + 1 < lines.count ? matchIndex + 1 : nil

        return LRCSyncSnapshot(
            currentLine: lines[matchIndex],
            currentIndex: matchIndex,
            upcomingLine: nextIndex != nil ? lines[nextIndex!] : nil,
            upcomingIndex: nextIndex,
            positionState: .inLyrics
        )
    }
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

enum LRCLIBResult {
    case synced(id: Int, lrcText: String)
    case notFound
}

final class LRCLIBClient {
    func fetchLyrics(title: String, artist: String, duration: TimeInterval?) async throws -> LRCLIBResult {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if let duration = duration, duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Lirik/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return .notFound }

        let dto = try JSONDecoder().decode(LRCLIBResponseDTO.self, from: data)
        if let synced = dto.syncedLyrics, !synced.isEmpty {
            return .synced(id: dto.id, lrcText: synced)
        }
        return .notFound
    }
}

// ─── AppleScript Now-Playing Reader ────────────────────────────────

struct MediaInfo {
    let title: String
    let artist: String
    let duration: TimeInterval
    let elapsed: TimeInterval
    let isPlaying: Bool
    let source: String
}

func isAppRunning(bundleIdentifier: String) -> Bool {
    return NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == bundleIdentifier
    }
}

func runAppleScript(_ source: String) -> String? {
    let script = NSAppleScript(source: source)
    var errorInfo: NSDictionary?
    let result = script?.executeAndReturnError(&errorInfo)
    return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func queryNowPlayingMedia() -> MediaInfo? {
    if isAppRunning(bundleIdentifier: "com.spotify.client") {
        let script = """
        tell application "Spotify"
            if player state is stopped then return "STOPPED"
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackDuration to (duration of current track) / 1000
            set trackPosition to player position
            set pState to player state as string
            return trackName & "|||" & trackArtist & "|||" & trackDuration & "|||" & trackPosition & "|||" & pState
        end tell
        """
        if let res = runAppleScript(script), res != "STOPPED" {
            let p = res.components(separatedBy: "|||")
            if p.count >= 5, !p[0].isEmpty {
                return MediaInfo(
                    title: p[0],
                    artist: p[1],
                    duration: TimeInterval(p[2]) ?? 0,
                    elapsed: TimeInterval(p[3]) ?? 0,
                    isPlaying: p[4].lowercased() == "playing",
                    source: "Spotify"
                )
            }
        }
    }

    if isAppRunning(bundleIdentifier: "com.apple.Music") {
        let script = """
        tell application "Music"
            if player state is stopped then return "STOPPED"
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackDuration to duration of current track
            set trackPosition to player position
            set pState to player state as string
            return trackName & "|||" & trackArtist & "|||" & trackDuration & "|||" & trackPosition & "|||" & pState
        end tell
        """
        if let res = runAppleScript(script), res != "STOPPED" {
            let p = res.components(separatedBy: "|||")
            if p.count >= 5, !p[0].isEmpty {
                return MediaInfo(
                    title: p[0],
                    artist: p[1],
                    duration: TimeInterval(p[2]) ?? 0,
                    elapsed: TimeInterval(p[3]) ?? 0,
                    isPlaying: p[4].lowercased() == "playing",
                    source: "Apple Music"
                )
            }
        }
    }

    return nil
}

// ─── Live Sync Engine Monitor ──────────────────────────────────────

print("╔══════════════════════════════════════════════════════╗")
print("║  Lirik — Phase 3: LRCSyncEngine Live Seek Detection  ║")
print("╚══════════════════════════════════════════════════════╝\n")

print("Checking currently playing song...")

guard let media = queryNowPlayingMedia() else {
    print("❌ No song playing in Spotify or Apple Music.")
    print("Please play a song (e.g. Yellow by Coldplay) and run again.")
    exit(0)
}

print("🎵 Currently Playing: \"\(media.title)\" by \(media.artist) [\(media.source)]")

let client = LRCLIBClient()

let semaphore = DispatchSemaphore(value: 0)

DispatchQueue.global().async {
    let group = DispatchGroup()
    group.enter()

    var fetchedLines: [LRCLine] = []

    Task {
        print("🌐 Fetching synced lyrics from LRCLIB...")
        if let res = try? await client.fetchLyrics(title: media.title, artist: media.artist, duration: media.duration),
           case .synced(_, let lrcText) = res {
            fetchedLines = LRCParser.parse(lrcText)
            print("✅ Parsed \(fetchedLines.count) timestamped lines.\n")
        } else {
            print("⚠️ No synced lyrics available for this song on LRCLIB.")
        }
        group.leave()
    }

    group.wait()

    guard !fetchedLines.isEmpty else {
        semaphore.signal()
        return
    }

    DispatchQueue.main.async {
        print("══════════════════════════════════════════════════════")
        print("STARTING LIVE SYNC MONITOR (Polling every 0.5s for 15s)")
        print("Instructions: Seek forward or backward in your media player!")
        print("Watch for [SEEK JUMP] events below:")
        print("══════════════════════════════════════════════════════\n")

        var lastElapsed: TimeInterval = -1.0
        var lastIndex: Int? = -99

        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let currentMedia = queryNowPlayingMedia() else { return }

            let elapsed = currentMedia.elapsed
            let delta = elapsed - lastElapsed

            let snapshot = LRCSyncEngine.resolve(elapsedTime: elapsed, lines: fetchedLines)

            func fmt(_ t: TimeInterval) -> String {
                let m = Int(t) / 60
                let s = Int(t) % 60
                let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 10)
                return String(format: "%02d:%02d.%d", m, s, ms)
            }

            let isSeek = lastElapsed >= 0 && (delta < -0.2 || delta > 2.5)

            if isSeek {
                let direction = delta < 0 ? "⏪ BACKWARD SEEK" : "⏩ FORWARD SEEK"
                print(String(format: "\n⚡️ [\(direction)] Jumping from %@ → %@", fmt(lastElapsed), fmt(elapsed)))
            }

            if isSeek || snapshot.currentIndex != lastIndex {
                let curText = snapshot.currentLine?.text ?? "(instrumental / gap)"
                let nxtText = snapshot.upcomingLine?.text ?? "(end of lyrics)"
                print(String(format: "   ⏱ [%@] CURRENT: \"%@\"  |  UPCOMING: \"%@\"", fmt(elapsed), curText, nxtText))
            }

            lastElapsed = elapsed
            lastIndex = snapshot.currentIndex
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
        timer.invalidate()
        print("\n⏱ Live sync monitor finished.")
        semaphore.signal()
    }
}

semaphore.wait()
