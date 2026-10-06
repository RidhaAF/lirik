//
//  NowPlayingTrack.swift
//  lirik
//
//  Value type representing a currently-playing track's metadata.
//  Consumed by LRCSyncEngine and LyricsWidget — this is the shared
//  currency type for "what is playing right now."
//

import Foundation

/// The media source that reported the currently-playing track.
enum NowPlayingSource: String, Sendable {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"
    case browser = "Browser"
    case unknown = "Unknown"
}

/// Snapshot of the currently-playing track at a point in time.
/// Pure value type — no side effects, no framework dependencies.
struct NowPlayingTrack: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    let elapsedTime: TimeInterval?
    let isPlaying: Bool
    let source: NowPlayingSource
    /// YouTube video ID for browser tracks (used for the closed-caption
    /// lyrics fallback). nil for Spotify / Apple Music / MediaRemote.
    let videoId: String?

    /// Two tracks represent the "same song" if title, artist, and source match,
    /// regardless of elapsed time or playback state. Used to detect
    /// track *changes* vs. mere position/state updates.
    ///
    /// Source is compared so that switching the same song between e.g.
    /// Spotify and a browser YouTube tab refetches (durations — and therefore
    /// cache keys and LRCLIB duration matching — usually differ per source).
    func isSameTrack(as other: NowPlayingTrack) -> Bool {
        return title == other.title && artist == other.artist && source == other.source
    }
}
