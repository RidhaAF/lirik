//
//  LRCSyncEngineTests.swift
//  lirik
//
//  Unit tests for LRCSyncEngine per AGENTS.md §9.
//

import XCTest
#if canImport(Foundation)
import Foundation
#endif

final class LRCSyncEngineTests: XCTestCase {

    let sampleLines = [
        LRCLine(timestamp: 10.0, text: "First line"),
        LRCLine(timestamp: 20.0, text: "Second line"),
        LRCLine(timestamp: 30.0, text: "Third line"),
        LRCLine(timestamp: 40.0, text: "Fourth line")
    ]

    func testEmptyLines() {
        let snapshot = LRCSyncEngine.resolve(elapsedTime: 15.0, lines: [])
        XCTAssertEqual(snapshot.positionState, .empty)
        XCTAssertNil(snapshot.currentLine)
        XCTAssertNil(snapshot.upcomingLine)
    }

    func testBeforeFirstLine() {
        let snapshot = LRCSyncEngine.resolve(elapsedTime: 5.0, lines: sampleLines)
        XCTAssertEqual(snapshot.positionState, .beforeFirstLine)
        XCTAssertNil(snapshot.currentLine)
        XCTAssertEqual(snapshot.upcomingLine?.text, "First line")
        XCTAssertEqual(snapshot.upcomingIndex, 0)
    }

    func testExactBoundaryMatch() {
        let snapshot = LRCSyncEngine.resolve(elapsedTime: 20.0, lines: sampleLines)
        XCTAssertEqual(snapshot.positionState, .inLyrics)
        XCTAssertEqual(snapshot.currentLine?.text, "Second line")
        XCTAssertEqual(snapshot.currentIndex, 1)
        XCTAssertEqual(snapshot.upcomingLine?.text, "Third line")
        XCTAssertEqual(snapshot.upcomingIndex, 2)
    }

    func testBetweenTimestamps() {
        let snapshot = LRCSyncEngine.resolve(elapsedTime: 25.5, lines: sampleLines)
        XCTAssertEqual(snapshot.positionState, .inLyrics)
        XCTAssertEqual(snapshot.currentLine?.text, "Second line")
        XCTAssertEqual(snapshot.currentIndex, 1)
        XCTAssertEqual(snapshot.upcomingLine?.text, "Third line")
        XCTAssertEqual(snapshot.upcomingIndex, 2)
    }

    func testAfterLastLine() {
        let snapshot1 = LRCSyncEngine.resolve(elapsedTime: 40.0, lines: sampleLines)
        XCTAssertEqual(snapshot1.positionState, .afterLastLine)
        XCTAssertEqual(snapshot1.currentLine?.text, "Fourth line")
        XCTAssertNil(snapshot1.upcomingLine)

        let snapshot2 = LRCSyncEngine.resolve(elapsedTime: 100.0, lines: sampleLines)
        XCTAssertEqual(snapshot2.positionState, .afterLastLine)
        XCTAssertEqual(snapshot2.currentLine?.text, "Fourth line")
        XCTAssertNil(snapshot2.upcomingLine)
    }

    func testNonMonotonicSeeks() {
        // Jump forward to 35s
        let snap1 = LRCSyncEngine.resolve(elapsedTime: 35.0, lines: sampleLines)
        XCTAssertEqual(snap1.currentLine?.text, "Third line")

        // Jump backward to 12s
        let snap2 = LRCSyncEngine.resolve(elapsedTime: 12.0, lines: sampleLines)
        XCTAssertEqual(snap2.currentLine?.text, "First line")

        // Jump forward to 45s (after last)
        let snap3 = LRCSyncEngine.resolve(elapsedTime: 45.0, lines: sampleLines)
        XCTAssertEqual(snap3.currentLine?.text, "Fourth line")

        // Jump backward to 2s (before first)
        let snap4 = LRCSyncEngine.resolve(elapsedTime: 2.0, lines: sampleLines)
        XCTAssertEqual(snap4.positionState, .beforeFirstLine)
    }
}
