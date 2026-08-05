//
//  AppleScriptBackend.swift
//  lirik
//
//  AppleScript-based polling backend for now-playing detection.
//  Primary backend on macOS 15.4+ where MediaRemote.framework is
//  blocked by entitlement enforcement (see MediaRemoteBackend.swift).
//
//  Queries Spotify and Apple Music via their AppleScript dictionaries
//  on a configurable polling interval. Only polls apps that are
//  currently running to avoid launching them unnecessarily.
//
//  Requires macOS Automation permission — the system will prompt
//  the user on first use for each target app.
//

import Foundation
import AppKit
import CoreServices

/// Polls Spotify and Apple Music via AppleScript to detect what's playing.
final class AppleScriptBackend {

    // MARK: - Configuration

    /// How often to poll, in seconds. 1s gives near-real-time detection
    /// without excessive CPU overhead.
    var pollingInterval: TimeInterval = 1.0

    // MARK: - State

    private var pollTimer: Timer?
    private var onUpdate: ((NowPlayingTrack?) -> Void)?
    /// Callback fired when macOS blocks AppleScript with error -1743 (Automation Permission Denied)
    var onPermissionDenied: ((String) -> Void)?

    // MARK: - Automation Permission Prompt Trigger

    /// Requests macOS Automation permission for the target application bundle identifier.
    /// Calling this on the main thread causes macOS to present the system authorization alert:
    /// "[App] would like to control [TargetApp]. [Don't Allow] [OK]"
    @discardableResult
    static func requestAutomationPermission(for bundleID: String) -> OSStatus {
        var address = AEAddressDesc()
        let data = bundleID.data(using: .utf8)!
        let status = data.withUnsafeBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return OSStatus(errAEEventNotPermitted) }
            return OSStatus(AECreateDesc(typeApplicationBundleID, base, data.count, &address))
        }
        guard status == noErr else { return status }

        let result = AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, true)
        AEDisposeDesc(&address)
        return result
    }

    // MARK: - Public API

    /// Performs a one-shot fetch of now-playing info from whichever
    /// supported app is currently running and playing.
    func fetchNowPlaying(completion: @escaping (NowPlayingTrack?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            let track = self?.queryNowPlaying()
            completion(track)
        }
    }

    /// Starts polling for now-playing changes. Calls `onUpdate` on the
    /// main thread whenever track info changes (including transitions
    /// to nil when nothing is playing).
    func startPolling(onUpdate: @escaping (NowPlayingTrack?) -> Void) {
        self.onUpdate = onUpdate

        // Prompt for permissions upfront on main thread if needed
        if isAppRunning(bundleIdentifier: "com.spotify.client") {
            Self.requestAutomationPermission(for: "com.spotify.client")
        }
        if isAppRunning(bundleIdentifier: "com.apple.Music") {
            Self.requestAutomationPermission(for: "com.apple.Music")
        }

        // Fire immediately, then repeat on interval
        DispatchQueue.main.async { [weak self] in
            let track = self?.queryNowPlaying()
            onUpdate(track)
        }

        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            DispatchQueue.main.async {
                let track = self?.queryNowPlaying()
                self?.onUpdate?(track)
            }
        }
    }

    /// Stops polling and cleans up the timer.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        onUpdate = nil
    }

    // MARK: - AppleScript queries

    /// Queries running media apps in priority order. Returns the first
    /// one that reports a playing track, or nil if nothing is playing.
    private func queryNowPlaying() -> NowPlayingTrack? {
        // Spotify takes priority because it's more common for lyrics use
        if isAppRunning(bundleIdentifier: "com.spotify.client") {
            if let track = querySpotify() {
                return track
            }
        }

        if isAppRunning(bundleIdentifier: "com.apple.Music") {
            if let track = queryAppleMusic() {
                return track
            }
        }

        return nil
    }

    /// Checks whether an app with the given bundle identifier is running,
    /// without launching it.
    private func isAppRunning(bundleIdentifier: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    // MARK: - Spotify

    private func querySpotify() -> NowPlayingTrack? {
        // Single compound query to minimize AppleScript round-trips.
        // Returns a record with all fields we need in one call.
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

        guard let result = runAppleScript(script, appName: "Spotify") else { return nil }
        if result == "|||STOPPED|||" { return nil }

        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        let title = parts[0].trimmingCharacters(in: .whitespaces)
        let artist = parts[1].trimmingCharacters(in: .whitespaces)
        let album = parts[2].trimmingCharacters(in: .whitespaces)
        let duration = TimeInterval(parts[3].trimmingCharacters(in: .whitespaces))
        let elapsed = TimeInterval(parts[4].trimmingCharacters(in: .whitespaces))
        let stateStr = parts[5].trimmingCharacters(in: .whitespaces).lowercased()

        guard !title.isEmpty else { return nil }

        return NowPlayingTrack(
            title: title,
            artist: artist,
            album: album.isEmpty ? nil : album,
            duration: duration,
            elapsedTime: elapsed,
            isPlaying: stateStr == "playing",
            source: .spotify
        )
    }

    // MARK: - Apple Music

    private func queryAppleMusic() -> NowPlayingTrack? {
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

        guard let result = runAppleScript(script, appName: "Apple Music") else { return nil }
        if result == "|||STOPPED|||" { return nil }

        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }

        let title = parts[0].trimmingCharacters(in: .whitespaces)
        let artist = parts[1].trimmingCharacters(in: .whitespaces)
        let album = parts[2].trimmingCharacters(in: .whitespaces)
        let duration = TimeInterval(parts[3].trimmingCharacters(in: .whitespaces))
        let elapsed = TimeInterval(parts[4].trimmingCharacters(in: .whitespaces))
        let stateStr = parts[5].trimmingCharacters(in: .whitespaces).lowercased()

        guard !title.isEmpty else { return nil }

        return NowPlayingTrack(
            title: title,
            artist: artist,
            album: album.isEmpty ? nil : album,
            duration: duration,
            elapsedTime: elapsed,
            isPlaying: stateStr == "playing",
            source: .appleMusic
        )
    }

    // MARK: - Script execution

    /// Executes an AppleScript string via /usr/bin/osascript process
    /// and returns the result as a trimmed string, or nil on error.
    private func runAppleScript(_ source: String, appName: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]

        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let output = output, !output.isEmpty {
                    return output
                }
            } else {
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if errStr.contains("1743") || errStr.contains("Not authorized") {
                    NSLog("[AppleScriptBackend] ⚠️ AUTOMATION PERMISSION DENIED (-1743) for \(appName).")
                    DispatchQueue.main.async { [weak self] in
                        self?.onPermissionDenied?(appName)
                    }
                }
            }
            return nil
        } catch {
            NSLog("[AppleScriptBackend] Process execution error: \(error.localizedDescription)")
            return nil
        }
    }
}
