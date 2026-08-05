#!/usr/bin/env swift
//
//  run_lrc_parser_tests.swift
//  lirik
//
//  Command-line runner for LRCParserTests.
//

import Foundation

struct LRCLine: Equatable, Sendable, Codable {
    let timestamp: TimeInterval
    let text: String
}

enum LRCParser {
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#,
        options: []
    )

    static func parse(_ lrcText: String) -> [LRCLine] {
        guard !lrcText.isEmpty else { return [] }
        var lines: [LRCLine] = []

        for rawLine in lrcText.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let nsLine = trimmed as NSString
            let matches = timestampPattern.matches(
                in: trimmed,
                options: [],
                range: NSRange(location: 0, length: nsLine.length)
            )

            if matches.isEmpty { continue }
            guard matches[0].range.location == 0 else { continue }

            var lastMatchEnd = 0
            var timestamps: [TimeInterval] = []

            for match in matches {
                if match.range.location > lastMatchEnd {
                    break
                }
                lastMatchEnd = match.range.location + match.range.length

                guard match.numberOfRanges > 2,
                      let minutes = extractInt(from: trimmed, range: match.range(at: 1)),
                      let seconds = extractInt(from: trimmed, range: match.range(at: 2)) else {
                    continue
                }

                let fractional: Double
                if match.numberOfRanges > 3 {
                    let fractionalRange = match.range(at: 3)
                    if fractionalRange.location != NSNotFound,
                       let fracStr = extractString(from: trimmed, range: fractionalRange) {
                        let padded = fracStr.padding(toLength: 3, withPad: "0", startingAt: 0)
                        fractional = (Double(padded) ?? 0) / 1000.0
                    } else {
                        fractional = 0
                    }
                } else {
                    fractional = 0
                }

                let timestamp = Double(minutes) * 60.0 + Double(seconds) + fractional
                timestamps.append(timestamp)
            }

            if timestamps.isEmpty { continue }

            let text = String(nsLine.substring(from: lastMatchEnd))
                .trimmingCharacters(in: .whitespaces)

            for ts in timestamps {
                lines.append(LRCLine(timestamp: ts, text: text))
            }
        }

        lines.sort { $0.timestamp < $1.timestamp }
        return lines
    }

    private static func extractString(from string: String, range: NSRange) -> String? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.location + range.length <= (string as NSString).length,
              let swiftRange = Range(range, in: string) else { return nil }
        return String(string[swiftRange])
    }

    private static func extractInt(from string: String, range: NSRange) -> Int? {
        guard let str = extractString(from: string, range: range) else { return nil }
        return Int(str)
    }
}

// ─── Test Runner ───────────────────────────────────────────────────

var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ message: String) {
    if condition {
        passCount += 1
        print("  ✅ \(message)")
    } else {
        failCount += 1
        print("  ❌ FAIL: \(message)")
    }
}

print("╔══════════════════════════════════════════════════════╗")
print("║         LRCParser Unit Test Suite                   ║")
print("╚══════════════════════════════════════════════════════╝\n")

print("Test Group 1: Empty & Whitespace Input")
let emptyResult = LRCParser.parse("")
assert(emptyResult.isEmpty, "Empty string returns empty array")
let wsResult = LRCParser.parse("   \n\t  ")
assert(wsResult.isEmpty, "Whitespace string returns empty array")

print("\nTest Group 2: Standard LRC Parsing")
let stdLRC = "[00:12.34] Line 1\n[01:05.50] Line 2"
let stdResult = LRCParser.parse(stdLRC)
assert(stdResult.count == 2, "Parsed 2 lines")
if stdResult.count >= 2 {
    assert(abs(stdResult[0].timestamp - 12.34) < 0.001, "Line 1 timestamp is 12.34")
    assert(stdResult[0].text == "Line 1", "Line 1 text matches")
    assert(abs(stdResult[1].timestamp - 65.50) < 0.001, "Line 2 timestamp is 65.50 (1:05.50)")
    assert(stdResult[1].text == "Line 2", "Line 2 text matches")
}

print("\nTest Group 3: Malformed & Unrecognized Lines")
let malformed = """
Invalid line without timestamp
[abc:def] Bad numbers
[00:12] No fractional seconds
[00:15.99] Valid line
[00:12.34 Not closed bracket
"""
let malformedResult = LRCParser.parse(malformed)
assert(malformedResult.count == 2, "Skipped invalid lines, kept 2 valid ones")
if malformedResult.count >= 2 {
    assert(abs(malformedResult[0].timestamp - 12.0) < 0.001, "No-fractional timestamp parsed as 12.0s")
    assert(abs(malformedResult[1].timestamp - 15.99) < 0.001, "Fractional timestamp parsed correctly")
}

print("\nTest Group 4: Multiple Timestamps on Same Line")
let multiLRC = "[00:10.00][00:20.00] Repeated chorus line"
let multiResult = LRCParser.parse(multiLRC)
assert(multiResult.count == 2, "Created 2 lines for 2 timestamps")
if multiResult.count >= 2 {
    assert(multiResult[0].timestamp == 10.0 && multiResult[0].text == "Repeated chorus line", "First timestamp line correct")
    assert(multiResult[1].timestamp == 20.0 && multiResult[1].text == "Repeated chorus line", "Second timestamp line correct")
}

print("\nTest Group 5: Fractional Seconds Normalization")
let fracLRC = "[00:01.5] Line 1\n[00:02.50] Line 2\n[00:03.500] Line 3"
let fracResult = LRCParser.parse(fracLRC)
if fracResult.count >= 3 {
    assert(abs(fracResult[0].timestamp - 1.5) < 0.001, ".5 normalized to 1.5s")
    assert(abs(fracResult[1].timestamp - 2.5) < 0.001, ".50 normalized to 2.5s")
    assert(abs(fracResult[2].timestamp - 3.5) < 0.001, ".500 normalized to 3.5s")
}

print("\nTest Group 6: Sorting Unsorted Timestamps")
let unsortedLRC = "[00:30.00] Later line\n[00:10.00] Earlier line"
let sortedResult = LRCParser.parse(unsortedLRC)
if sortedResult.count >= 2 {
    assert(sortedResult[0].timestamp == 10.0 && sortedResult[0].text == "Earlier line", "Earlier line sorted first")
    assert(sortedResult[1].timestamp == 30.0 && sortedResult[1].text == "Later line", "Later line sorted second")
}

print("\nTest Group 7: Instrumental Gaps (Blank Lyric Text)")
let gapLRC = "[00:10.00] Singing\n[00:20.00]\n[00:30.00] More singing"
let gapResult = LRCParser.parse(gapLRC)
assert(gapResult.count == 3, "Preserved 3 lines including gap")
if gapResult.count >= 2 {
    assert(gapResult[1].text == "", "Blank line text is empty string")
}

print("\n══════════════════════════════════════════════════════")
print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
print("══════════════════════════════════════════════════════")

if failCount > 0 {
    exit(1)
} else {
    exit(0)
}
