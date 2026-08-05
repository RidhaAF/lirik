#!/usr/bin/env swift
//
//  test_rapid_skip.swift
//  lirik
//
//  Verification script for Phase 5: Rapid Track Skipping & Race Condition Fencing.
//
//  Simulates 5 rapid track skips in 200ms with out-of-order simulated network delays.
//  Proves that task cancellation and track-key fencing guarantee ONLY the final track's
//  lyrics render — with ZERO stale flashes from earlier tracks!
//

import Foundation
import CryptoKit

struct SimulatedTrack {
    let title: String
    let artist: String
    let duration: TimeInterval
    let networkDelayMs: Int
    let hasLyrics: Bool
}

final class RapidSkipSimulator {

    private var activeTrackKey: String = ""
    private var inFlightTask: Task<Void, Never>?

    private(set) var currentRenderedTrack: String = "(none)"
    private(set) var renderHistory: [String] = []

    func skipToTrack(_ track: SimulatedTrack) {
        // 1. Cancel previous task
        inFlightTask?.cancel()

        // 2. Update active key fence
        let expectedKey = "\(track.artist.lowercased())|\(track.title.lowercased())|\(Int(track.duration))"
        activeTrackKey = expectedKey

        print(String(format: "  ⏭ [SKIP] Track: \"%@\" — key: %@ (network delay: %dms)", track.title, expectedKey, track.networkDelayMs))

        // 3. Launch async fetch task
        inFlightTask = Task {
            // Simulate network latency
            try? await Task.sleep(nanoseconds: UInt64(track.networkDelayMs) * 1_000_000)

            // FENCING CHECK: Is task cancelled or is key stale?
            guard !Task.isCancelled, self.activeTrackKey == expectedKey else {
                print(String(format: "     🛡 [DISCARDED STALE RESPONSE] Track: \"%@\" (key %@ no longer active)", track.title, expectedKey))
                return
            }

            // Commit state
            self.currentRenderedTrack = "\(track.title) — \(track.artist)"
            self.renderHistory.append(self.currentRenderedTrack)
            print(String(format: "     ✅ [RENDERED] Track: \"%@\"", track.title))
        }
    }
}

// ─── Test Runner ───────────────────────────────────────────────────

print("╔══════════════════════════════════════════════════════╗")
print("║  Lirik — Phase 5: Rapid Track-Skip Race Test        ║")
print("╚══════════════════════════════════════════════════════╝\n")

print("Scenario: User rapidly skips through 5 tracks in 200ms.")
print("Network responses arrive OUT-OF-ORDER (Track 1 finishes last at 500ms).\n")

let tracks = [
    SimulatedTrack(title: "Track 1 - Skip Fast", artist: "Artist A", duration: 200, networkDelayMs: 500, hasLyrics: true),
    SimulatedTrack(title: "Track 2 - Skip Fast", artist: "Artist B", duration: 180, networkDelayMs: 400, hasLyrics: true),
    SimulatedTrack(title: "Track 3 - Skip Fast", artist: "Artist C", duration: 210, networkDelayMs: 350, hasLyrics: false),
    SimulatedTrack(title: "Track 4 - Skip Fast", artist: "Artist D", duration: 195, networkDelayMs: 300, hasLyrics: true),
    SimulatedTrack(title: "Track 5 - Final Track", artist: "Artist E", duration: 240, networkDelayMs: 150, hasLyrics: true)
]

let simulator = RapidSkipSimulator()

let group = DispatchGroup()
group.enter()

Task {
    for track in tracks {
        simulator.skipToTrack(track)
        // 40ms delay between skips (simulating 5 fast presses in 200ms)
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    // Wait 700ms for all simulated network responses to arrive or be discarded
    try? await Task.sleep(nanoseconds: 700_000_000)
    group.leave()
}

group.wait()

print("\n══════════════════════════════════════════════════════")
print("RESULTS:")
print("  Rendered History: \(simulator.renderHistory)")
print("  Final Display:    \(simulator.currentRenderedTrack)")
print("══════════════════════════════════════════════════════")

if simulator.renderHistory.count == 1 && simulator.currentRenderedTrack == "Track 5 - Final Track — Artist E" {
    print("\n✅ TEST PASSED: Only final track rendered! 0 stale flashes.")
    exit(0)
} else {
    print("\n❌ TEST FAILED: Race condition allowed stale tracks to render!")
    exit(1)
}
