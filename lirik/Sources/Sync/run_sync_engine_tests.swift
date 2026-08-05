#!/usr/bin/env swift
//
//  run_sync_engine_tests.swift
//  lirik
//
//  Command-line runner for LRCSyncEngineTests.
//

import Foundation

struct LRCLine: Equatable, Sendable, Codable {
    let timestamp: TimeInterval
    let text: String
}

enum LRCPositionState: Equatable, Sendable {
    case empty
    case beforeFirstLine
    case inLyrics
    case afterLastLine
}

struct LRCSyncSnapshot: Equatable, Sendable {
    let currentLine: LRCLine?
    let currentIndex: Int?
    let upcomingLine: LRCLine?
    let upcomingIndex: Int?
    let positionState: LRCPositionState
}

enum LRCSyncEngine {
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

        if elapsedTime < lines[0].timestamp {
            return LRCSyncSnapshot(
                currentLine: nil,
                currentIndex: nil,
                upcomingLine: lines[0],
                upcomingIndex: 0,
                positionState: .beforeFirstLine
            )
        }

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
print("║         LRCSyncEngine Unit Test Suite               ║")
print("╚══════════════════════════════════════════════════════╝\n")

let sampleLines = [
    LRCLine(timestamp: 10.0, text: "First line"),
    LRCLine(timestamp: 20.0, text: "Second line"),
    LRCLine(timestamp: 30.0, text: "Third line"),
    LRCLine(timestamp: 40.0, text: "Fourth line")
]

print("Test Group 1: Empty Lines Input")
let emptySnap = LRCSyncEngine.resolve(elapsedTime: 15.0, lines: [])
assert(emptySnap.positionState == .empty, "State is empty")
assert(emptySnap.currentLine == nil, "Current line is nil")

print("\nTest Group 2: Intro (Before First Timestamp)")
let introSnap = LRCSyncEngine.resolve(elapsedTime: 5.0, lines: sampleLines)
assert(introSnap.positionState == .beforeFirstLine, "State is beforeFirstLine")
assert(introSnap.currentLine == nil, "Current line is nil")
assert(introSnap.upcomingLine?.text == "First line", "Upcoming line is First line")
assert(introSnap.upcomingIndex == 0, "Upcoming index is 0")

print("\nTest Group 3: Exact Timestamp Boundary Match")
let exactSnap = LRCSyncEngine.resolve(elapsedTime: 20.0, lines: sampleLines)
assert(exactSnap.positionState == .inLyrics, "State is inLyrics")
assert(exactSnap.currentLine?.text == "Second line", "Current line is Second line")
assert(exactSnap.currentIndex == 1, "Current index is 1")
assert(exactSnap.upcomingLine?.text == "Third line", "Upcoming line is Third line")

print("\nTest Group 4: Interpolated Between Timestamps")
let interSnap = LRCSyncEngine.resolve(elapsedTime: 25.5, lines: sampleLines)
assert(interSnap.currentLine?.text == "Second line", "Current line remains Second line at 25.5s")
assert(interSnap.upcomingLine?.text == "Third line", "Upcoming line is Third line")

print("\nTest Group 5: Outro (At/After Last Timestamp)")
let outroSnap = LRCSyncEngine.resolve(elapsedTime: 40.0, lines: sampleLines)
assert(outroSnap.positionState == .afterLastLine, "State is afterLastLine at exact last timestamp")
assert(outroSnap.currentLine?.text == "Fourth line", "Current line is Fourth line")
assert(outroSnap.upcomingLine == nil, "Upcoming line is nil")

let lateSnap = LRCSyncEngine.resolve(elapsedTime: 100.0, lines: sampleLines)
assert(lateSnap.positionState == .afterLastLine, "State is afterLastLine at 100s")
assert(lateSnap.currentLine?.text == "Fourth line", "Current line remains Fourth line")

print("\nTest Group 6: Non-Monotonic Seeks / Jumps")
let jump1 = LRCSyncEngine.resolve(elapsedTime: 35.0, lines: sampleLines)
assert(jump1.currentLine?.text == "Third line", "Forward seek to 35s resolves Third line")

let jump2 = LRCSyncEngine.resolve(elapsedTime: 12.0, lines: sampleLines)
assert(jump2.currentLine?.text == "First line", "Backward seek to 12s resolves First line instantly")

let jump3 = LRCSyncEngine.resolve(elapsedTime: 45.0, lines: sampleLines)
assert(jump3.currentLine?.text == "Fourth line", "Forward seek to 45s resolves Fourth line")

let jump4 = LRCSyncEngine.resolve(elapsedTime: 2.0, lines: sampleLines)
assert(jump4.positionState == .beforeFirstLine, "Backward seek to 2s resolves beforeFirstLine")

print("\n══════════════════════════════════════════════════════")
print("RESULTS: \(passCount) PASSED, \(failCount) FAILED")
print("══════════════════════════════════════════════════════")

if failCount > 0 {
    exit(1)
} else {
    exit(0)
}
