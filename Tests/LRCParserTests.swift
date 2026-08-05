//
//  LRCParserTests.swift
//  lirik
//
//  Unit tests for LRCParser per AGENTS.md §9.
//  Covers:
//  - Standard LRC parsing
//  - Empty input
//  - Malformed lines (missing brackets, non-numeric timestamps)
//  - Duplicate timestamps & multi-timestamp lines
//  - Fractional seconds variations (mm:ss.x, mm:ss.xx, mm:ss.xxx)
//  - Unsorted input ordering
//

import XCTest
#if canImport(Foundation)
import Foundation
#endif

final class LRCParserTests: XCTestCase {

    func testEmptyInput() {
        let result = LRCParser.parse("")
        XCTAssertTrue(result.isEmpty, "Empty string should return empty array")

        let whitespaceOnly = LRCParser.parse("   \n\n  \t ")
        XCTAssertTrue(whitespaceOnly.isEmpty, "Whitespace-only input should return empty array")
    }

    func testStandardLRC() {
        let lrc = """
        [00:12.34] Line 1
        [01:05.50] Line 2
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].timestamp, 12.34, accuracy: 0.001)
        XCTAssertEqual(result[0].text, "Line 1")
        XCTAssertEqual(result[1].timestamp, 65.50, accuracy: 0.001)
        XCTAssertEqual(result[1].text, "Line 2")
    }

    func testMalformedLines() {
        let lrc = """
        Invalid line without timestamp
        [abc:def] Bad numbers
        [00:12] No fractional seconds
        [00:15.99] Valid line
        [00:99.99] Still parsed if regex matches digits
        [00:12.34 Not closed bracket
        """
        let result = LRCParser.parse(lrc)
        
        // [00:12] is valid (0 min, 12 sec, 0 frac)
        // [00:15.99] is valid (15.99 sec)
        // [00:99.99] is valid (99.99 sec = 1 min 39.99 sec)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].timestamp, 12.0, accuracy: 0.001)
        XCTAssertEqual(result[0].text, "No fractional seconds")
        XCTAssertEqual(result[1].timestamp, 15.99, accuracy: 0.001)
        XCTAssertEqual(result[1].text, "Valid line")
    }

    func testMultiAndDuplicateTimestamps() {
        let lrc = """
        [00:10.00][00:20.00] Repeated chorus line
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].timestamp, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].text, "Repeated chorus line")
        XCTAssertEqual(result[1].timestamp, 20.0, accuracy: 0.001)
        XCTAssertEqual(result[1].text, "Repeated chorus line")
    }

    func testFractionalSecondsNormalization() {
        let lrc = """
        [00:01.5] Single digit frac (.500s)
        [00:02.50] Two digit frac (.500s)
        [00:03.500] Three digit frac (.500s)
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].timestamp, 1.5, accuracy: 0.001)
        XCTAssertEqual(result[1].timestamp, 2.5, accuracy: 0.001)
        XCTAssertEqual(result[2].timestamp, 3.5, accuracy: 0.001)
    }

    func testUnsortedInputIsSorted() {
        let lrc = """
        [00:30.00] Later line
        [00:10.00] Earlier line
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].timestamp, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].text, "Earlier line")
        XCTAssertEqual(result[1].timestamp, 30.0, accuracy: 0.001)
        XCTAssertEqual(result[1].text, "Later line")
    }

    func testInstrumentalGapPreserved() {
        let lrc = """
        [00:10.00] Singing
        [00:20.00]
        [00:30.00] More singing
        """
        let result = LRCParser.parse(lrc)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1].timestamp, 20.0, accuracy: 0.001)
        XCTAssertEqual(result[1].text, "")
    }
}
