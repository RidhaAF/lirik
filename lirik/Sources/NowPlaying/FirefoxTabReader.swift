//
//  FirefoxTabReader.swift
//  lirik
//
//  YouTube-in-Firefox detection via the macOS Accessibility API.
//
//  Firefox ships no AppleScript dictionary for tabs or page JavaScript
//  (Mozilla bugs 369901 and 939528 are still open), so the AppleScript path
//  in BrowserTabPoller cannot work for it at all. What Firefox does expose is
//  its accessibility tree: each window has an AXTabGroup whose children are
//  the tab elements, each carrying the page title.
//
//  That yields the track title and nothing else — no URL, no video ID, no
//  playback position. Consequently Firefox tracks:
//    - never get closed-caption lyrics (needs a video ID),
//    - never get YouTube thumbnails (needs a video ID),
//    - advance their static lyrics from PlaybackEstimate, not real position.
//
//  Requires Accessibility permission (System Settings → Privacy & Security →
//  Accessibility → Pock), which is a different grant from the Automation
//  permission the AppleScript browsers need. Main-thread only: AX calls are
//  synchronous and the poller already runs on the main runloop.
//

import Foundation
import AppKit
import ApplicationServices

/// Reads the playing YouTube tab title out of Firefox and its forks.
final class FirefoxTabReader {

    // MARK: - Supported applications

    /// Firefox and the forks that share its (non-)AppleScript behaviour.
    struct Target: Equatable {
        let displayName: String
        let bundleIdentifier: String

        static let all: [Target] = [
            Target(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox"),
            Target(displayName: "Zen", bundleIdentifier: "app.zen-browser.zen"),
            Target(displayName: "LibreWolf", bundleIdentifier: "io.gitlab.librewolf-community"),
        ]
    }

    // MARK: - State

    /// Whether we've already asked macOS to show the Accessibility prompt.
    /// Only once per session — the poller runs every second.
    private var accessibilityPrompted = false

    /// Whether we've already logged the "grant Accessibility" guidance.
    private var permissionNoted = false

    /// Advances position for title-only tracks (see PlaybackEstimate).
    private var estimate = PlaybackEstimate()

    // MARK: - Public API

    /// Returns the YouTube track playing in a Firefox-family browser, or nil.
    func queryYouTube() -> NowPlayingTrack? {
        guard let target = runningTarget() else {
            estimate.reset()
            return nil
        }
        guard hasAccessibilityPermission() else {
            notePermissionNeeded(for: target)
            return nil
        }

        let app = AXUIElementCreateApplication(target.processIdentifier)
        guard let windows = copyAttribute(app, "AXWindows") as? [AXUIElement] else {
            estimate.reset()
            return nil
        }

        for window in windows {
            for title in candidateTitles(in: window) where Self.isYouTubeTitle(title) {
                let (artist, song) = BrowserTabPoller.splitArtistTitle(from: title)
                guard !song.isEmpty else { continue }
                let elapsed = estimate.elapsed(
                    forKey: BrowserTabPoller.estimateKey(title: song, artist: artist),
                    at: Date()
                )
                return NowPlayingTrack(
                    title: song,
                    artist: artist,
                    album: nil,
                    duration: nil,
                    elapsedTime: elapsed,
                    // No position and no pause state — assume playing. A paused
                    // video keeps its lyrics advancing, which is the documented
                    // cost of having no JS bridge.
                    isPlaying: true,
                    source: .browser,
                    videoId: nil
                )
            }
        }

        estimate.reset()
        return nil
    }

    // MARK: - Pure helpers (unit-testable, no browser needed)

    /// Whether a tab title looks like a single YouTube video.
    ///
    /// Deliberately requires the " - YouTube" suffix that YouTube appends to
    /// the page title. The bare titles "YouTube" and "YouTube Music" are
    /// excluded: they carry no track information, so matching them would
    /// replace whatever lyrics are showing with a meaningless track.
    static func isYouTubeTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(" - YouTube") || trimmed.hasSuffix(" - YouTube Music")
    }

    // MARK: - Running application

    private struct RunningTarget {
        let target: Target
        let processIdentifier: pid_t
    }

    private func runningTarget() -> RunningTarget? {
        for target in Target.all {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == target.bundleIdentifier
            }) {
                return RunningTarget(target: target, processIdentifier: app.processIdentifier)
            }
        }
        return nil
    }

    // MARK: - Accessibility permission

    /// Checks (and on first call, prompts for) Accessibility permission.
    /// macOS shows the prompt once per app identity; after that the user has
    /// to toggle Pock on in System Settings.
    private func hasAccessibilityPermission() -> Bool {
        let prompt = !accessibilityPrompted
        accessibilityPrompted = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func notePermissionNeeded(for target: RunningTarget) {
        guard !permissionNoted else { return }
        permissionNoted = true
        NSLog("[FirefoxTabReader] Accessibility permission needed for %@ — enable Pock in System Settings → Privacy & Security → Accessibility to read YouTube tabs.", target.target.displayName)
    }

    // MARK: - Accessibility tree reads

    /// Tab titles for one window, most specific source first: the tab group's
    /// children, then the window title (which mirrors the active tab).
    private func candidateTitles(in window: AXUIElement) -> [String] {
        var titles: [String] = []
        if let group = tabGroup(in: window) {
            titles = tabTitles(in: group)
        }
        if let windowTitle = stringAttribute(window, "AXTitle"), !windowTitle.isEmpty {
            titles.append(windowTitle)
        }
        return titles
    }

    /// Finds the tab strip inside a window. Depth-limited because the AX tree
    /// of a browser window also contains the whole web content.
    private func tabGroup(in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        var visited = 0

        func walk(_ element: AXUIElement, depth: Int) {
            guard found == nil, depth <= 4, visited < 200 else { return }
            visited += 1
            if stringAttribute(element, "AXRole") == "AXTabGroup" {
                found = element
                return
            }
            for child in children(of: element) {
                walk(child, depth: depth + 1)
            }
        }

        walk(window, depth: 0)
        return found
    }

    /// Titles of the tab elements inside a tab group. Firefox exposes tabs as
    /// AXRadioButton; AXTab covers other Gecko builds.
    private func tabTitles(in group: AXUIElement) -> [String] {
        children(of: group).compactMap { element -> String? in
            let role = stringAttribute(element, "AXRole") ?? ""
            guard role == "AXRadioButton" || role == "AXTab" else { return nil }
            guard let title = stringAttribute(element, "AXTitle"), !title.isEmpty else { return nil }
            return title
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, "AXChildren") as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        copyAttribute(element, name) as? String
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
