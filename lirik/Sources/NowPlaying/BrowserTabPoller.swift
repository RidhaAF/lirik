//
//  BrowserTabPoller.swift
//  lirik
//
//  YouTube-in-browser now-playing detection via AppleScript tab polling.
//  Consumed only by AppleScriptBackend, which is the primary backend on
//  macOS 15.4+ where MediaRemote.framework is blocked by entitlement
//  enforcement and can no longer report browser playback system-wide
//  (see MediaRemoteBackend.swift).
//
//  For each running browser (Safari, Chrome, Edge) it finds the first tab
//  on a youtube.com/watch URL, splits the tab title into artist/title,
//  and queries the page's <video> element for live position so synced LRC
//  lyrics keep working — not just the static fallback.
//
//  Permissions: each browser needs macOS Automation permission (the system
//  prompts on first poll via a subprocess trigger, same pattern as
//  AppleScriptBackend). Every browser — Safari, Chrome, Edge — additionally
//  needs View/Develop → Allow JavaScript from Apple Events enabled for the
//  position query; without it only the title is readable and the track is
//  returned without position (LyricsWidget then degrades to auto-advancing
//  static lyrics).
//
//  Must be called on the main thread — NSAppleScript is not thread-safe,
//  and AppleScriptBackend already polls on the main runloop.
//

import Foundation
import AppKit

/// Polls supported browsers for a YouTube watch tab that is playing.
/// Returns nil when no browser is running or no YouTube tab exists.
final class BrowserTabPoller {

    // MARK: - Supported browsers

    enum Browser: CaseIterable {
        case safari
        case chrome
        case edge

        var bundleIdentifier: String {
            switch self {
            case .safari: return "com.apple.Safari"
            case .chrome: return "com.google.Chrome"
            case .edge: return "com.microsoft.Edge"
            }
        }

        /// Name shown in logs and permission guidance.
        var displayName: String {
            switch self {
            case .safari: return "Safari"
            case .chrome: return "Google Chrome"
            case .edge: return "Microsoft Edge"
            }
        }

        /// AppleScript application name.
        var scriptName: String { displayName }
    }

    // MARK: - State

    /// Browsers we've already logged a -1743 denial for this session.
    /// One log line per browser — the 1s poller would otherwise spam.
    private var permissionNoted: Set<String> = []

    /// Browsers we've already spawned a TCC dialog trigger for.
    /// Only one subprocess per browser per session — avoids spamming.
    private var dialogTriggered: Set<String> = []

    // MARK: - Public API

    /// Returns the first YouTube track found across supported browsers.
    /// When several browsers have YouTube tabs, a tab whose video reports
    /// playing wins over paused ones; otherwise the first paused tab is
    /// returned so the widget still shows *something* instead of nothing.
    func queryYouTube() -> NowPlayingTrack? {
        var pausedFallback: NowPlayingTrack?
        for browser in Browser.allCases {
            guard isAppRunning(bundleIdentifier: browser.bundleIdentifier) else { continue }
            guard let track = queryBrowser(browser) else { continue }
            if track.isPlaying {
                return track
            }
            if pausedFallback == nil {
                pausedFallback = track
            }
        }
        return pausedFallback
    }

    // MARK: - Per-browser query

    /// Finds the YouTube tab in one browser and reads its video position.
    private func queryBrowser(_ browser: Browser) -> NowPlayingTrack? {
        guard let found = findYouTubeTab(in: browser) else { return nil }

        let (artist, title) = Self.splitArtistTitle(from: found.title)
        guard !title.isEmpty else { return nil }

        // Position query is best-effort: without it (Safari JS toggle off,
        // CSP quirks) we still return the track so static lyrics can show.
        if let position = readVideoPosition(in: browser, window: found.windowIndex, tab: found.tabIndex) {
            let duration: TimeInterval? = position.duration > 0 ? position.duration : nil
            return NowPlayingTrack(
                title: title,
                artist: artist,
                album: nil,
                duration: duration,
                elapsedTime: max(0, position.elapsed),
                isPlaying: position.isPlaying,
                source: .browser
            )
        }

        return NowPlayingTrack(
            title: title,
            artist: artist,
            album: nil,
            duration: nil,
            elapsedTime: nil,
            isPlaying: true,
            source: .browser
        )
    }

    /// Locates the first YouTube watch tab in a browser.
    /// Returns the tab title plus window/tab indices for the position query.
    ///
    /// Matches watch, Shorts, youtu.be shares, live streams, and YouTube
    /// Music — all of which render a <video> element the position probe
    /// can read. Plain youtube.com home/channel pages are excluded since
    /// they carry no single playable track.
    private func findYouTubeTab(in browser: Browser) -> (title: String, windowIndex: Int, tabIndex: Int)? {
        let titleProperty = browser == .safari ? "name" : "title"
        let script = """
        tell application "\(browser.scriptName)"
            repeat with w from 1 to (count of windows)
                repeat with t from 1 to (count of tabs of window w)
                    try
                        set tabURL to URL of tab t of window w
                    on error
                        set tabURL to ""
                    end try
                    if tabURL contains "youtube.com/watch" or tabURL contains "youtube.com/shorts/" or tabURL contains "youtube.com/live/" or tabURL contains "youtu.be/" or tabURL contains "music.youtube.com" then
                        set tabTitle to \(titleProperty) of tab t of window w
                        return tabURL & "|||" & tabTitle & "|||" & w & "|||" & t
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """

        guard let output = runAppleScript(script, browser: browser) else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 4,
              let windowIndex = Int(parts[2].trimmingCharacters(in: .whitespaces)),
              let tabIndex = Int(parts[3].trimmingCharacters(in: .whitespaces)) else { return nil }
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return (title, windowIndex, tabIndex)
    }

    /// Reads currentTime/duration/paused from the tab's <video> element.
    /// The JS deliberately uses single quotes only so it can be embedded
    /// in an AppleScript double-quoted string without escaping.
    private func readVideoPosition(in browser: Browser, window: Int, tab: Int) -> (elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool)? {
        let js = "(() => { const v = document.querySelector('video'); if (!v) return ''; return v.currentTime + '|||' + (isFinite(v.duration) ? v.duration : 0) + '|||' + (v.paused ? 'paused' : 'playing'); })()"

        let script: String
        switch browser {
        case .safari:
            script = "tell application \"\(browser.scriptName)\" to do JavaScript \"\(js)\" in tab \(tab) of window \(window)"
        case .chrome, .edge:
            script = "tell application \"\(browser.scriptName)\" to execute tab \(tab) of window \(window) javascript \"\(js)\""
        }

        guard let output = runAppleScript(script, browser: browser) else { return nil }
        return Self.parsePositionOutput(output)
    }

    // MARK: - Pure parsers (unit-testable, no browser needed)

    /// Splits a YouTube tab title into artist/title.
    /// Browsers append " - YouTube" to every tab title; music uploads are
    /// conventionally "Artist - Title", so the first " - " separates them.
    /// Uploads without an artist separator keep the whole title with an
    /// "Unknown Artist" placeholder, matching MediaRemoteBackend's behavior.
    static func splitArtistTitle(from rawTitle: String) -> (artist: String, title: String) {
        // Trim first: real tab titles can carry trailing whitespace that
        // would otherwise defeat the hasSuffix checks below. Bare forms
        // cover degenerate titles holding nothing but the suffix itself.
        var cleaned = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - YouTube Music", " - YouTube", "- YouTube Music", "- YouTube"] {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
                break
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if let separator = cleaned.range(of: " - ") {
            let artist = String(cleaned[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(cleaned[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty && !title.isEmpty {
                return (artist, title)
            }
        }
        return ("Unknown Artist", cleaned)
    }

    /// Parses the "elapsed|||duration|||playing|paused" JS probe output.
    /// Returns nil for empty/malformed output (no <video> on the page).
    static func parsePositionOutput(_ output: String) -> (elapsed: TimeInterval, duration: TimeInterval, isPlaying: Bool)? {
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 3 else { return nil }
        // JS always formats numbers with "." decimals; normalize anyway
        // since TimeInterval parsing is locale-sensitive (see AppleScriptBackend).
        let elapsedStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let durationStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let elapsed = TimeInterval(elapsedStr),
              let duration = TimeInterval(durationStr) else { return nil }
        let state = parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (elapsed, duration, state == "playing")
    }

    // MARK: - Helpers

    private func isAppRunning(bundleIdentifier: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    /// Runs an AppleScript snippet, returning trimmed output or nil on error.
    /// -1743 (Automation denied) is logged once per browser per session and
    /// swallowed — the browser is lowest-priority input, so a missing grant
    /// must not surface as a permission alert over working music apps.
    /// The system still shows its own Allow/Deny dialog on first attempt.
    private func runAppleScript(_ source: String, browser: Browser) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                // First denial: spawn a /usr/bin/osascript subprocess to force
                // the TCC Allow/Deny dialog. In-process NSAppleScript cannot
                // trigger the dialog when Pock was launched via Spotlight,
                // Finder-open, or our own build script — same root cause as
                // AppleScriptBackend.triggerDialogViaSubprocess. The subprocess
                // runs outside Pock's process tree, so the dialog appears.
                if !dialogTriggered.contains(browser.displayName) {
                    dialogTriggered.insert(browser.displayName)
                    triggerDialogViaSubprocess(for: browser)
                }
                if !permissionNoted.contains(browser.displayName) {
                    permissionNoted.insert(browser.displayName)
                    NSLog("[BrowserTabPoller] Automation permission needed for %@ — allow Pock in System Settings → Privacy & Security → Automation. All browsers also need View → Developer → Allow JavaScript from Apple Events for live position.", browser.displayName)
                }
            } else if code != -128 && code != -1719 && code != -1728 {
                // -128 user cancelled, -1719 object not found (closed tab),
                // -1728 app not running — all benign at 1s cadence.
                NSLog("[BrowserTabPoller] %@ script error \(code): \(error[NSAppleScript.errorMessage] as? String ?? "unknown")", browser.displayName)
            }
            return nil
        }

        guard let output = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        return output
    }

    // MARK: - Subprocess dialog trigger

    /// Spawns `/usr/bin/osascript` asking the browser for its own name —
    /// a no-op query whose only purpose is making macOS present the
    /// Automation permission dialog outside Pock's process tree.
    /// Fire-and-forget; the next 1s poll picks up the granted state.
    private func triggerDialogViaSubprocess(for browser: Browser) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"\(browser.scriptName)\" to get name"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
                NSLog("[BrowserTabPoller] Subprocess dialog trigger for %@ exited with code \(process.terminationStatus)", browser.displayName)
            } catch {
                NSLog("[BrowserTabPoller] Failed to spawn subprocess for %@: \(error.localizedDescription)", browser.displayName)
            }
        }
    }
}
