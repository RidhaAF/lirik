//
//  LRCParser.swift
//  lirik
//
//  Parses raw LRC-formatted text into an array of timestamped lyric lines.
//  LRC format reference: "[mm:ss.xx] lyric text" per line.
//
//  Unit-testable in isolation per AGENTS.md §9.
//

import Foundation

/// A single timestamped lyric line parsed from LRC format.
struct LRCLine: Equatable, Sendable, Codable {
    /// Timestamp in seconds from the start of the track.
    let timestamp: TimeInterval
    /// The lyric text for this line (may be empty for instrumental gaps).
    let text: String
}

/// Parses raw LRC text into sorted, timestamped lyric lines.
enum LRCParser {

    // Matches "[mm:ss.xx]" or "[mm:ss.xxx]" or "[mm:ss]" at the start of a line.
    // Captures: minutes, seconds, optional centiseconds/milliseconds.
    private static let timestampPattern = try! NSRegularExpression(  // provably safe: literal regex pattern that compiles
        pattern: #"^\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#,
        options: []
    )

    /// Parses raw LRC text into an array of `LRCLine`, sorted by timestamp.
    ///
    /// - Lines without a valid `[mm:ss.xx]` prefix are silently skipped.
    /// - Multiple timestamps on the same line (e.g., `[00:01.00][00:30.00] text`)
    ///   produce one `LRCLine` per timestamp, each with the same text.
    /// - Blank lyric text after a timestamp is preserved (represents
    ///   instrumental gaps in LRC convention).
    /// - Duplicate timestamps are preserved — the caller (LRCSyncEngine)
    ///   decides how to handle them.
    ///
    /// Returns an empty array for empty or entirely-unparseable input.
    static func parse(_ lrcText: String) -> [LRCLine] {
        guard !lrcText.isEmpty else { return [] }

        var lines: [LRCLine] = []

        for rawLine in lrcText.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Extract all timestamps from this line. LRC allows multiple
            // timestamps before a single text segment, e.g.:
            //   [00:01.50][01:30.50] Some repeated lyric
            let nsLine = trimmed as NSString
            let matches = timestampPattern.matches(
                in: trimmed,
                options: [],
                range: NSRange(location: 0, length: nsLine.length)
            )

            if matches.isEmpty { continue }

            // Find where the text starts (after the last timestamp bracket)
            var lastMatchEnd = 0
            var timestamps: [TimeInterval] = []

            for match in matches {
                lastMatchEnd = match.range.location + match.range.length

                guard let minutes = extractInt(from: trimmed, range: match.range(at: 1)),
                      let seconds = extractInt(from: trimmed, range: match.range(at: 2)) else {
                    continue
                }

                let fractionalRange = match.range(at: 3)
                let fractional: Double
                if fractionalRange.location != NSNotFound,
                   let fracStr = extractString(from: trimmed, range: fractionalRange) {
                    // Normalize: "5" → 0.5, "50" → 0.5, "500" → 0.5, "05" → 0.05
                    let padded = fracStr.padding(toLength: 3, withPad: "0", startingAt: 0)
                    fractional = (Double(padded) ?? 0) / 1000.0
                } else {
                    fractional = 0
                }

                let timestamp = Double(minutes) * 60.0 + Double(seconds) + fractional
                timestamps.append(timestamp)
            }

            let text = String(nsLine.substring(from: lastMatchEnd))
                .trimmingCharacters(in: .whitespaces)

            for ts in timestamps {
                lines.append(LRCLine(timestamp: ts, text: text))
            }
        }

        // Sort by timestamp — LRC files aren't guaranteed to be ordered
        lines.sort { $0.timestamp < $1.timestamp }

        return lines
    }

    // MARK: - Helpers

    private static func extractInt(from string: String, range: NSRange) -> Int? {
        guard range.location != NSNotFound else { return nil }
        guard let swiftRange = Range(range, in: string) else { return nil }
        return Int(string[swiftRange])
    }

    private static func extractString(from string: String, range: NSRange) -> String? {
        guard range.location != NSNotFound else { return nil }
        guard let swiftRange = Range(range, in: string) else { return nil }
        return String(string[swiftRange])
    }
}
