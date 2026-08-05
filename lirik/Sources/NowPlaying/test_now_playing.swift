#!/usr/bin/env swift
//
//  test_now_playing.swift
//  lirik
//
//  Standalone test harness for NowPlayingWatcher.
//  Run from the repo root:
//    swift lirik/Sources/NowPlaying/test_now_playing.swift
//
//  This is a self-contained script that duplicates the essential types
//  inline (NowPlayingTrack, AppleScriptBackend) so it can run without
//  a full Xcode build. The real code lives in the separate .swift files;
//  this script exists solely for quick manual verification.
//
//  Expected output:
//    1. Play a track in Spotify → see track info printed
//    2. Skip to next → see "TRACK CHANGED" log
//    3. Switch to Apple Music → see source change
//    4. Pause → see "isPlaying: false"
//

import Foundation
import AppKit

// ─── Inline types (mirrors of the real code) ───────────────────────

enum NowPlayingSource: String {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"
    case browser = "Browser"
    case unknown = "Unknown"
}

struct NowPlayingTrack: Equatable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    let elapsedTime: TimeInterval?
    let isPlaying: Bool
    let source: NowPlayingSource

    func isSameTrack(as other: NowPlayingTrack) -> Bool {
        return title == other.title && artist == other.artist
    }
}

// ─── Inline AppleScript backend ────────────────────────────────────

func isAppRunning(bundleIdentifier: String) -> Bool {
    return NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == bundleIdentifier
    }
}

func runAppleScript(_ source: String) -> String? {
    let script = NSAppleScript(source: source)
    var errorInfo: NSDictionary?
    let result = script?.executeAndReturnError(&errorInfo)
    if let error = errorInfo {
        let num = error[NSAppleScript.errorNumber] as? Int ?? 0
        if num != -128 && num != -1728 {
            print("  ⚠ AppleScript error \(num): \(error[NSAppleScript.errorMessage] as? String ?? "?")")
        }
        return nil
    }
    return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func querySpotify() -> NowPlayingTrack? {
    let script = """
    tell application "Spotify"
        if player state is stopped then return "|||STOPPED|||"
        set trackName to name of current track
        set trackArtist to artist of current track
        set trackAlbum to album of current track
        set trackDuration to (duration of current track) / 1000
        set trackPosition to player position
        set pState to player state as string
        return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackDuration & "|||" & trackPosition & "|||" & pState
    end tell
    """
    guard let result = runAppleScript(script), result != "|||STOPPED|||" else { return nil }
    let p = result.components(separatedBy: "|||")
    guard p.count >= 6 else { return nil }
    let title = p[0].trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }
    return NowPlayingTrack(
        title: title,
        artist: p[1].trimmingCharacters(in: .whitespaces),
        album: p[2].trimmingCharacters(in: .whitespaces).isEmpty ? nil : p[2].trimmingCharacters(in: .whitespaces),
        duration: TimeInterval(p[3].trimmingCharacters(in: .whitespaces)),
        elapsedTime: TimeInterval(p[4].trimmingCharacters(in: .whitespaces)),
        isPlaying: p[5].trimmingCharacters(in: .whitespaces).lowercased() == "playing",
        source: .spotify
    )
}

func queryAppleMusic() -> NowPlayingTrack? {
    let script = """
    tell application "Music"
        if player state is stopped then return "|||STOPPED|||"
        set trackName to name of current track
        set trackArtist to artist of current track
        set trackAlbum to album of current track
        set trackDuration to duration of current track
        set trackPosition to player position
        set pState to player state as string
        return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackDuration & "|||" & trackPosition & "|||" & pState
    end tell
    """
    guard let result = runAppleScript(script), result != "|||STOPPED|||" else { return nil }
    let p = result.components(separatedBy: "|||")
    guard p.count >= 6 else { return nil }
    let title = p[0].trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }
    return NowPlayingTrack(
        title: title,
        artist: p[1].trimmingCharacters(in: .whitespaces),
        album: p[2].trimmingCharacters(in: .whitespaces).isEmpty ? nil : p[2].trimmingCharacters(in: .whitespaces),
        duration: TimeInterval(p[3].trimmingCharacters(in: .whitespaces)),
        elapsedTime: TimeInterval(p[4].trimmingCharacters(in: .whitespaces)),
        isPlaying: p[5].trimmingCharacters(in: .whitespaces).lowercased() == "playing",
        source: .appleMusic
    )
}

func fetchNowPlaying() -> NowPlayingTrack? {
    if isAppRunning(bundleIdentifier: "com.spotify.client") {
        if let track = querySpotify() { return track }
    }
    if isAppRunning(bundleIdentifier: "com.apple.Music") {
        if let track = queryAppleMusic() { return track }
    }
    return nil
}

// ─── Test harness ──────────────────────────────────────────────────

let duration: TimeInterval = 60
let pollInterval: TimeInterval = 1.0

print("╔══════════════════════════════════════════════════════╗")
print("║     Lirik — NowPlayingWatcher Test Harness          ║")
print("╠══════════════════════════════════════════════════════╣")
print("║ Polling every \(pollInterval)s for \(Int(duration))s                          ║")
print("║ Backend: AppleScript (macOS 15.4+ mode)             ║")
print("║                                                      ║")
print("║ Instructions:                                        ║")
print("║  1. Open Spotify and play a song                     ║")
print("║  2. Skip to next track — watch for TRACK CHANGED     ║")
print("║  3. Pause — watch for isPlaying: false               ║")
print("║  4. Try Apple Music — watch for source change        ║")
print("║                                                      ║")
print("║ First run will trigger macOS Automation prompts.     ║")
print("╚══════════════════════════════════════════════════════╝")
print()

var previousTrack: NowPlayingTrack?
let startTime = Date()

func formatElapsed(_ t: TimeInterval?) -> String {
    guard let t else { return "--:--" }
    let m = Int(t) / 60
    let s = Int(t) % 60
    return String(format: "%d:%02d", m, s)
}

func formatDuration(_ t: TimeInterval?) -> String {
    guard let t else { return "--:--" }
    let m = Int(t) / 60
    let s = Int(t) % 60
    return String(format: "%d:%02d", m, s)
}

let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
    let now = fetchNowPlaying()
    let elapsed = Date().timeIntervalSince(startTime)

    if elapsed >= duration {
        print("\n⏱  Test duration reached (\(Int(duration))s). Exiting.")
        exit(0)
    }

    // Detect track change
    switch (previousTrack, now) {
    case (nil, nil):
        return // Still nothing playing
    case (nil, .some(let track)):
        print("\n🎵 TRACK STARTED")
        print("   \(track.title) — \(track.artist)")
        if let album = track.album { print("   Album: \(album)") }
        print("   Source: \(track.source.rawValue)")
        print("   Duration: \(formatDuration(track.duration))")
        print("   Playing: \(track.isPlaying)")
    case (.some(let old), nil):
        print("\n⏹  TRACK STOPPED (was: \(old.title) — \(old.artist))")
    case (.some(let old), .some(let new)):
        if !old.isSameTrack(as: new) {
            print("\n🔄 TRACK CHANGED")
            print("   From: \(old.title) — \(old.artist) [\(old.source.rawValue)]")
            print("   To:   \(new.title) — \(new.artist) [\(new.source.rawValue)]")
            if let album = new.album { print("   Album: \(album)") }
            print("   Duration: \(formatDuration(new.duration))")
        } else if old.isPlaying != new.isPlaying {
            let state = new.isPlaying ? "▶️  RESUMED" : "⏸  PAUSED"
            print("   \(state) at \(formatElapsed(new.elapsedTime))")
        } else {
            // Same track, same state — just print position
            print("   ♪ \(formatElapsed(now?.elapsedTime)) / \(formatDuration(now?.duration))", terminator: "\r")
            fflush(stdout)
        }
    }

    previousTrack = now
}

// Run the first check immediately
let firstTrack = fetchNowPlaying()
if let track = firstTrack {
    print("🎵 CURRENTLY PLAYING")
    print("   \(track.title) — \(track.artist)")
    if let album = track.album { print("   Album: \(album)") }
    print("   Source: \(track.source.rawValue)")
    print("   Position: \(formatElapsed(track.elapsedTime)) / \(formatDuration(track.duration))")
    print("   Playing: \(track.isPlaying)")
} else {
    print("⏹  Nothing playing. Start a track in Spotify or Apple Music.")
}
previousTrack = firstTrack

RunLoop.main.run(until: Date(timeIntervalSinceNow: duration + 1))
