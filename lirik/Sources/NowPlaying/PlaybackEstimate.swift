//
//  PlaybackEstimate.swift
//  lirik
//
//  Locally advanced playback position for browsers that can't report one.
//
//  Firefox has no AppleScript tab interface at all, Arc's JS bridge returns
//  no values, and any Chromium build can have "Allow JavaScript from Apple
//  Events" switched off. In all three cases the widget still knows *what*
//  is playing but not *where* in the video it is.
//
//  This deliberately deviates from AGENTS.md §7 ("treat MediaRemote elapsed
//  time as the single source of truth, don't run a separate local timer"):
//  there is no source of truth to defer to here. The estimate only ever
//  fills a gap where elapsed time would otherwise be nil, which would pin
//  static lyrics to the first line forever. Any real position reading
//  supersedes it; BrowserTabPoller calls reset() as soon as one arrives.
//

import Foundation

/// Tracks wall-clock time since a title-only track was first seen.
/// Pure value type with an injected `now`, so the advance/reset behaviour is
/// unit-testable without sleeping. Main-thread only (one poller owns it).
struct PlaybackEstimate {

    /// Identity of the track the clock is currently counting for.
    private(set) var key: String?

    /// When the current key was first observed. nil when no clock is running.
    private(set) var startedAt: Date?

    /// Elapsed time for a track key, starting the clock on first sight and
    /// restarting it whenever the key changes (track change, seek to a new
    /// video, or a different upload with the same title).
    mutating func elapsed(forKey key: String, at now: Date) -> TimeInterval {
        guard self.key == key, let startedAt else {
            self.key = key
            self.startedAt = now
            return 0
        }
        // Clock skew or a backwards system clock must not produce negative
        // elapsed time; LRCSyncEngine treats that as "before the first line".
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Drops the clock. Called when a real position reading supersedes the
    /// estimate, so the next title-only track starts from zero.
    mutating func reset() {
        key = nil
        startedAt = nil
    }
}
