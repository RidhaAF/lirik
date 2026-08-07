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
//  Permission strategy:
//  - NSAppleScript (in-process) for regular 1s polling (fast, lightweight).
//  - When -1743 is first hit, spawn a ONE-TIME `/usr/bin/osascript` subprocess
//    to trigger the TCC permission dialog. The subprocess runs outside Pock's
//    process tree, so the dialog appears regardless of how Pock was launched
//    (Spotlight, Terminal, etc.).
//  - After the dialog is resolved (Allow or Deny), NSAppleScript resumes
//    regular polling.
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

    // MARK: - Permission retry tracking

    /// How many consecutive -1743 errors we've seen per app.
    /// Reset to 0 on any successful query for that app.
    private var consecutiveDenials: [String: Int] = [:]

    /// Maximum consecutive -1743 errors before we give up and
    /// show the "Permission Required" UI. With 1s polling, this
    /// gives the user ~8 seconds to respond to the dialog.
    private let maxConsecutiveDenialsBeforeAlert = 8

    /// Tracks which apps we've already spawned a subprocess for.
    /// Only one subprocess per app per session — avoids spamming.
    private var subprocessTriggered: Set<String> = []

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

        // Reset state on fresh start
        consecutiveDenials.removeAll()
        subprocessTriggered.removeAll()

        // Fire immediately. NSAppleScript does regular in-process polling.
        // If permission isn't granted yet, the first -1743 will trigger
        // a one-time subprocess to show the system dialog.
        DispatchQueue.main.async { [weak self] in
            let track = self?.queryNowPlaying()
            self?.onUpdate?(track)
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

    // MARK: - Script execution

    /// Executes an AppleScript string on main thread and returns the result as a
    /// trimmed string, or nil on error.
    ///
    /// Error -1743 strategy:
    /// 1. On first -1743 for an app → spawn `/usr/bin/osascript` subprocess to
    ///    trigger the TCC permission dialog (works even when Pock is launched
    ///    from Spotlight, unlike in-process NSAppleScript).
    /// 2. Continue polling with NSAppleScript.
    /// 3. If consecutive denials reach threshold → fire `onPermissionDenied`.
    /// 4. If any query succeeds → reset counter + mark as resolved.
    private func runAppleScript(_ source: String, appName: String) -> String? {
        let appleScript = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int ?? 0
            if errorNumber == -1743 {
                let current = consecutiveDenials[appName] ?? 0
                let next = current + 1
                consecutiveDenials[appName] = next

                // On first denial, spawn a subprocess to trigger the TCC dialog.
                // The subprocess (/usr/bin/osascript) runs OUTSIDE Pock's process
                // tree, so macOS presents the dialog regardless of launch method.
                if next == 1 && !subprocessTriggered.contains(appName) {
                    subprocessTriggered.insert(appName)
                    triggerDialogViaSubprocess(for: appName)
                }

                if next < maxConsecutiveDenialsBeforeAlert {
                    NSLog("[AppleScriptBackend] Permission denied (-1743) for \(appName) — retry \(next)/\(maxConsecutiveDenialsBeforeAlert)")
                } else if next == maxConsecutiveDenialsBeforeAlert {
                    NSLog("[AppleScriptBackend] ⚠️ PERSISTENT DENIAL for \(appName) after \(next) attempts. User must enable Pock → \(appName) in System Settings → Privacy & Security → Automation.")
                    DispatchQueue.main.async { [weak self] in
                        self?.onPermissionDenied?(appName)
                    }
                }
            } else if errorNumber != -128 && errorNumber != -1728 {
                // -128 = user cancelled, -1728 = app not running — both benign
                NSLog("[AppleScriptBackend] Script error \(errorNumber): \(error[NSAppleScript.errorMessage] as? String ?? "unknown")")
            }
            return nil
        }

        // Script succeeded — permission is granted. Reset everything.
        if consecutiveDenials[appName] != nil {
            NSLog("[AppleScriptBackend] Permission resolved for \(appName) — resetting")
            consecutiveDenials.removeValue(forKey: appName)
            subprocessTriggered.remove(appName)
        }

        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Subprocess dialog trigger

    /// Spawns `/usr/bin/osascript` as a subprocess to trigger the macOS
    /// Automation permission dialog. This subprocess runs independently
    /// of Pock, so the TCC dialog appears even when Pock was launched
    /// from Spotlight (where in-process AppleEvents can't trigger it).
    ///
    /// We use a lightweight script that just asks for the player state —
    /// enough to trigger the dialog without heavy overhead.
    /// The subprocess is fire-and-forget; we don't need its result.
    private func triggerDialogViaSubprocess(for appName: String) {
        let script: String
        if appName == "Spotify" {
            script = "tell application \"Spotify\" to get player state"
        } else {
            script = "tell application \"Music\" to get player state"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        // Discard output — we only care about the side effect (triggering dialog)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Run on a background thread to avoid blocking the main thread
        // while the dialog is showing.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    NSLog("[AppleScriptBackend] Subprocess dialog trigger for \(appName) succeeded — permission granted")
                } else {
                    NSLog("[AppleScriptBackend] Subprocess dialog trigger for \(appName) exited with code \(exitCode) (user may have denied)")
                }
            } catch {
                NSLog("[AppleScriptBackend] Failed to spawn subprocess for \(appName): \(error.localizedDescription)")
            }
        }
    }
}
