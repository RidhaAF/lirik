//
//  LRCSyncEngine.swift
//  lirik
//
//  Sync engine matching playback elapsed time against parsed LRC lines.
//
//  Per AGENTS.md §7:
//  - Treat elapsed-time updates as the single source of truth.
//  - No separate local clock/timer to avoid drift accumulation.
//  - Handles non-monotonic playback time (seeks/jumps) statelessly.
//

import Foundation

/// Position state of the sync engine relative to lyric timestamps.
enum LRCPositionState: Equatable, Sendable {
    /// No lyrics lines provided.
    case empty
    /// Playback position is before the first timestamped lyric line (e.g. intro).
    case beforeFirstLine
    /// Playback position is actively within the lyrics sequence.
    case inLyrics
    /// Playback position is after the final timestamped lyric line (e.g. outro).
    case afterLastLine
}

/// Active sync resolution result at a given elapsed time snapshot.
struct LRCSyncSnapshot: Equatable, Sendable {
    /// Current active lyric line, if any.
    let currentLine: LRCLine?
    /// Index of current line in the parsed lines array, if any.
    let currentIndex: Int?
    /// Next upcoming lyric line, if any.
    let upcomingLine: LRCLine?
    /// Index of upcoming line in the parsed lines array, if any.
    let upcomingIndex: Int?
    /// State of playback relative to lyric timestamps.
    let positionState: LRCPositionState
}

/// Stateless sync engine resolving active lyric lines from elapsed time.
enum LRCSyncEngine {

    /// Resolves the sync snapshot for a given elapsed time and sorted LRC lines.
    ///
    /// - Parameters:
    ///   - elapsedTime: Current playback time in seconds (single source of truth).
    ///   - lines: Sorted array of `LRCLine` values.
    /// - Returns: `LRCSyncSnapshot` containing current & upcoming lines and position state.
    static func resolve(elapsedTime: TimeInterval, lines: [LRCLine]) -> LRCSyncSnapshot {
        guard !lines.isEmpty else {
            return LRCSyncSnapshot(
                currentLine: nil,
                currentIndex: nil,
                upcomingLine: nil,
                upcomingIndex: nil,
                positionState: .empty
            )
        }

        // Edge Case 1: Elapsed time before the first lyric timestamp
        if elapsedTime < lines[0].timestamp {
            return LRCSyncSnapshot(
                currentLine: nil,
                currentIndex: nil,
                upcomingLine: lines[0],
                upcomingIndex: 0,
                positionState: .beforeFirstLine
            )
        }

        // Edge Case 2: Elapsed time at or after the last lyric timestamp
        if elapsedTime >= lines.last!.timestamp {
            let lastIdx = lines.count - 1
            return LRCSyncSnapshot(
                currentLine: lines[lastIdx],
                currentIndex: lastIdx,
                upcomingLine: nil,
                upcomingIndex: nil,
                positionState: .afterLastLine
            )
        }

        // Edge Case 3 & Standard Case: Find highest index `i` where lines[i].timestamp <= elapsedTime
        // Binary search for O(log N) efficiency
        var low = 0
        var high = lines.count - 1
        var matchIndex = 0

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timestamp <= elapsedTime {
                matchIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let nextIndex = matchIndex + 1 < lines.count ? matchIndex + 1 : nil

        return LRCSyncSnapshot(
            currentLine: lines[matchIndex],
            currentIndex: matchIndex,
            upcomingLine: nextIndex != nil ? lines[nextIndex!] : nil,
            upcomingIndex: nextIndex,
            positionState: .inLyrics
        )
    }
}
