//
//  LyricOffsetStore.swift
//  lirik
//
//  Persists manual lyric-timing offsets per YouTube video. Album-timed
//  lyrics assume the song starts at 0:00, but music videos often open with
//  dialogue/skits (or cut the intro), shifting every line; and videos
//  without caption tracks can't be auto-calibrated. The offset (seconds,
//  added to elapsed playback time) is saved per video ID from the
//  preferences panel and applied by LyricsWidget on every render.
//

import Foundation

/// Per-video lyric timing adjustments, UserDefaults-backed.
/// Main-thread only (widget callbacks and preferences panel).
final class LyricOffsetStore {

    static let offsetsKey = "io.github.ridhaaf.lirik.videoLyricOffsets"
    static let lastVideoKey = "io.github.ridhaaf.lirik.lastVideoId"

    /// Posted when the playing video changes. userInfo carries "videoId"
    /// (empty string for non-YouTube tracks). Observed by the preferences
    /// panel to enable the offset stepper for the current video.
    static let trackChangedNotification = Notification.Name("io.github.ridhaaf.lirik.videoTrackChanged")

    /// Posted when an offset is saved. Observed by LyricsWidget to apply
    /// the new value live without waiting for a track change.
    static let offsetChangedNotification = Notification.Name("io.github.ridhaaf.lirik.videoOffsetChanged")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the saved offset for a video, or 0 when none was set.
    func offset(forVideoId videoId: String) -> TimeInterval {
        guard !videoId.isEmpty else { return 0 }
        return (defaults.dictionary(forKey: Self.offsetsKey) as? [String: Double])?[videoId] ?? 0
    }

    /// Saves an offset. Zero removes the entry instead of storing it, so
    /// untouched videos leave no residue.
    func setOffset(_ offset: TimeInterval, forVideoId videoId: String) {
        guard !videoId.isEmpty else { return }
        var stored = defaults.dictionary(forKey: Self.offsetsKey) as? [String: Double] ?? [:]
        if offset == 0 {
            stored.removeValue(forKey: videoId)
        } else {
            stored[videoId] = offset
        }
        defaults.set(stored, forKey: Self.offsetsKey)
    }
}
