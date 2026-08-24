//
//  NowPlayingWatcher.swift
//  lirik
//
//  Single source of truth for "what is playing right now," per AGENTS.md §7.
//  Consumers (LRCSyncEngine, LyricsWidget) interact only with this type —
//  never with MediaRemoteBackend or AppleScriptBackend directly.
//
//  Auto-selects backend at startup:
//  1. Tries MediaRemote (works on macOS < 15.4)
//  2. Falls back to AppleScript polling (works on all supported macOS)
//

import Foundation

/// Watches system-wide now-playing state and notifies consumers of
/// track changes and elapsed-time updates.
final class NowPlayingWatcher {

    // MARK: - Public callbacks

    /// Called when the playing track changes (including nil → track,
    /// track → nil, and track → different track). Not called for
    /// mere elapsed-time updates within the same track.
    var onTrackChange: ((NowPlayingTrack?) -> Void)?

    /// Called on every poll/notification cycle with the latest elapsed
    /// time. This is the value LRCSyncEngine uses to pick the current
    /// lyric line — per AGENTS.md §7, MediaRemote elapsed-time updates
    /// are the single source of truth for sync position.
    var onElapsedTimeUpdate: ((TimeInterval) -> Void)?

    /// Called when macOS Automation permission is denied for a media app.
    var onPermissionDenied: ((String) -> Void)?

    /// The most recently observed track. nil if nothing is playing
    /// or no backend has reported yet.
    private(set) var currentTrack: NowPlayingTrack?

    // MARK: - Backends

    private let mediaRemoteBackend = MediaRemoteBackend()
    private let appleScriptBackend = AppleScriptBackend()

    private enum ActiveBackend {
        case mediaRemote
        case appleScript
    }
    private var activeBackend: ActiveBackend?

    // MARK: - Lifecycle

    /// Starts watching for now-playing changes. Auto-detects which
    /// backend to use based on what actually works on this OS version.
    func startWatching() {
        // Idempotent: if a backend is already active, just force a refresh
        // rather than double-registering observers and timers.
        if activeBackend != nil {
            NSLog("[NowPlayingWatcher] startWatching called while already active — forcing refresh instead")
            forceRefresh()
            return
        }

        NSLog("[NowPlayingWatcher] Starting — probing backends...")

        if mediaRemoteBackend.isAvailable {
            probeMediaRemoteThenFallback()
        } else {
            NSLog("[NowPlayingWatcher] MediaRemote not available, using AppleScript")
            startAppleScriptBackend()
        }
    }

    /// Forces an immediate refetch from whichever backend is active.
    /// Call this after the Touch Bar wakes, the widget re-appears, or the
    /// system wakes from sleep — situations where our polling timers may
    /// have quiesced or MediaRemote snapshots may be stale.
    ///
    /// Safe to call even before a backend is selected (no-op in that case).
    func forceRefresh() {
        switch activeBackend {
        case .mediaRemote:
            mediaRemoteBackend.fetchNowPlaying(timeout: 2.0) { [weak self] track in
                self?.handleUpdate(track)
            }
        case .appleScript:
            appleScriptBackend.fetchNowPlaying { [weak self] track in
                self?.handleUpdate(track)
            }
        case .none:
            break
        }
    }

    /// Stops all watching and cleans up.
    func stopWatching() {
        NSLog("[NowPlayingWatcher] Stopping")
        mediaRemoteBackend.stopObserving()
        appleScriptBackend.stopPolling()
        activeBackend = nil
    }

    // MARK: - Backend selection

    /// Tries a one-shot MediaRemote fetch with a short timeout.
    /// If the callback fires, we use MediaRemote going forward.
    /// If it times out (macOS 15.4+), we fall back to AppleScript.
    private func probeMediaRemoteThenFallback() {
        NSLog("[NowPlayingWatcher] Probing MediaRemote (2s timeout)...")

        mediaRemoteBackend.fetchNowPlaying(timeout: 2.0) { [weak self] track in
            guard let self else { return }

            if track != nil {
                NSLog("[NowPlayingWatcher] MediaRemote responded — using it as backend")
                self.startMediaRemoteBackend()
            } else {
                // Ambiguous: could be "nothing playing" or "API blocked."
                // Try one more time after a short delay, then fall back.
                // The heuristic: if both fetches return nil, assume blocked.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.mediaRemoteBackend.fetchNowPlaying(timeout: 2.0) { [weak self] retryTrack in
                        guard let self else { return }

                        if retryTrack != nil {
                            NSLog("[NowPlayingWatcher] MediaRemote responded on retry — using it")
                            self.startMediaRemoteBackend()
                        } else {
                            NSLog("[NowPlayingWatcher] MediaRemote timed out twice — falling back to AppleScript")
                            self.startAppleScriptBackend()
                        }
                    }
                }
            }
        }
    }

    // MARK: - MediaRemote backend

    private func startMediaRemoteBackend() {
        activeBackend = .mediaRemote

        mediaRemoteBackend.startObserving { [weak self] info in
            guard let self else { return }
            let newTrack = self.mediaRemoteBackend.parseInfo(info)
            self.handleUpdate(newTrack)
        }
    }

    // MARK: - AppleScript backend

    private func startAppleScriptBackend() {
        activeBackend = .appleScript

        appleScriptBackend.onPermissionDenied = { [weak self] appName in
            self?.onPermissionDenied?(appName)
        }

        appleScriptBackend.startPolling { [weak self] newTrack in
            guard let self else { return }
            self.handleUpdate(newTrack)
        }
    }

    // MARK: - Unified update handling

    /// Processes an update from either backend. Detects track changes
    /// vs. mere elapsed-time updates and fires the appropriate callbacks.
    private func handleUpdate(_ newTrack: NowPlayingTrack?) {
        // Track change detection
        let isNewTrack: Bool
        switch (currentTrack, newTrack) {
        case (nil, nil):
            return // No change: still nothing playing
        case (nil, .some):
            isNewTrack = true
        case (.some, nil):
            isNewTrack = true
        case let (.some(old), .some(new)):
            isNewTrack = !old.isSameTrack(as: new)
        }

        if isNewTrack {
            currentTrack = newTrack
            onTrackChange?(newTrack)
        } else {
            // Same track — update stored state for elapsed time / play state
            currentTrack = newTrack
        }

        // Always fire elapsed-time updates so the sync engine stays current
        if let elapsed = newTrack?.elapsedTime {
            onElapsedTimeUpdate?(elapsed)
        }
    }
}
