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
//  IMPORTANT: All AppleScript execution uses `/usr/bin/osascript` as a
//  child process rather than in-process `NSAppleScript`. This is
//  critical because Lirik runs as a plugin loaded into Pock.app's
//  process space — macOS TCC suppresses the Automation permission
//  dialog for bundles loaded into another app (error -1743). Spawning
//  `osascript` as a separate process escapes Pock's plugin sandbox,
//  allowing the TCC dialog to appear correctly.
//

import Foundation
import AppKit

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

    /// Serial queue for running osascript without blocking the main thread
    private let scriptQueue = DispatchQueue(label: "io.github.ridhaaf.lirik.applescript", qos: .userInitiated)

    // MARK: - Public API

    /// Performs a one-shot fetch of now-playing info from whichever
    /// supported app is currently running and playing.
    func fetchNowPlaying(completion: @escaping (NowPlayingTrack?) -> Void) {
        scriptQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let track = self.queryNowPlaying()
            DispatchQueue.main.async { completion(track) }
        }
    }

    /// Starts polling for now-playing changes. Calls `onUpdate` on the
    /// main thread whenever track info changes (including transitions
    /// to nil when nothing is playing).
    func startPolling(onUpdate: @escaping (NowPlayingTrack?) -> Void) {
        self.onUpdate = onUpdate

        // Fire immediately on the script queue
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let track = self.queryNowPlaying()
            DispatchQueue.main.async { onUpdate(track) }
        }

        // Schedule repeating timer on main thread; each tick dispatches
        // the actual script work to the serial scriptQueue
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer = Timer.scheduledTimer(
                withTimeInterval: self.pollingInterval,
                repeats: true
            ) { [weak self] _ in
                self?.scriptQueue.async { [weak self] in
                    guard let self else { return }
                    let track = self.queryNowPlaying()
                    DispatchQueue.main.async {
                        self.onUpdate?(track)
                    }
                }
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
    /// Called on scriptQueue — must not touch the main thread directly.
    private func queryNowPlaying() -> NowPlayingTrack? {
        // isAppRunning uses NSWorkspace which is thread-safe for reads
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
        // Single compound query to minimize osascript round-trips.
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
        let durationStr = parts[3].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let elapsedStr = parts[4].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let duration = TimeInterval(durationStr)
        let elapsed = TimeInterval(elapsedStr)
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
        let durationStr = parts[3].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let elapsedStr = parts[4].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let duration = TimeInterval(durationStr)
        let elapsed = TimeInterval(elapsedStr)
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

    // MARK: - Script execution via osascript child process

    /// Executes an AppleScript string by spawning `/usr/bin/osascript` as a
    /// child process. Returns the trimmed stdout on success, or nil on error.
    ///
    /// Using a child process instead of in-process `NSAppleScript` is the
    /// key fix: when Lirik runs as a Pock plugin loaded into Pock.app's
    /// address space, macOS TCC suppresses the Automation permission dialog
    /// for in-process AppleScript calls (error -1743). The separate
    /// `osascript` process is outside Pock's sandbox, so TCC correctly
    /// presents the "[App] wants to control [TargetApp]" consent prompt.
    ///
    /// Called on scriptQueue — synchronous and blocking by design.
    private func runAppleScript(_ source: String, appName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            NSLog("[AppleScriptBackend] Failed to launch osascript: \(error.localizedDescription)")
            return nil
        }

        process.waitUntilExit()

        let status = process.terminationStatus

        if status != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

            // osascript exits with status 1 and stderr containing the error
            // number when macOS blocks Automation. Detect -1743 in stderr.
            if stderrString.contains("-1743") {
                NSLog("[AppleScriptBackend] ⚠️ AUTOMATION PERMISSION DENIED (-1743) for \(appName). Grant permission in System Settings -> Privacy & Security -> Automation.")
                DispatchQueue.main.async { [weak self] in
                    self?.onPermissionDenied?(appName)
                }
            } else if !stderrString.contains("-128") && !stderrString.contains("-1728") {
                // -128 = user cancelled, -1728 = app not running / no current track — both expected
                NSLog("[AppleScriptBackend] osascript error (exit \(status)) for \(appName): \(stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return nil
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: stdoutData, encoding: .utf8) else { return nil }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
