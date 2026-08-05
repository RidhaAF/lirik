//
//  StylusProgressView.swift
//  lirik
//
//  Custom NSView subclass rendering a tape/vinyl-groove progress indicator.
//  Per PRD §8:
//  - Thin horizontal groove line
//  - Stylus / tape-head position marker (warm gold accent)
//  - Replaces default OS progress bar controls
//

import Foundation
import AppKit

final class StylusProgressView: NSView {

    /// Progress position between 0.0 and 1.0.
    var progress: Double = 0.0 {
        didSet {
            let clamped = max(0.0, min(1.0, progress))
            if abs(clamped - oldValue) > 0.001 {
                needsDisplay = true
            }
        }
    }

    /// Whether playback is paused (grays out stylus marker).
    var isPaused: Bool = false {
        didSet {
            if isPaused != oldValue {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let width = bounds.width
        let height = bounds.height
        guard width > 0 && height > 0 else { return }

        let midY = height / 2.0

        // 1. Draw the tape groove background track line (2px thin line)
        let groovePath = NSBezierPath()
        groovePath.move(to: NSPoint(x: 0, y: midY))
        groovePath.line(to: NSPoint(x: width, y: midY))
        groovePath.lineWidth = 1.5

        let grooveColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3)
        grooveColor.setStroke()
        groovePath.stroke()

        // 2. Calculate stylus position
        let stylusX = CGFloat(progress) * width

        // 3. Draw played groove highlight (from start to stylus position)
        if stylusX > 0 {
            let playedPath = NSBezierPath()
            playedPath.move(to: NSPoint(x: 0, y: midY))
            playedPath.line(to: NSPoint(x: stylusX, y: midY))
            playedPath.lineWidth = 2.0

            let playedColor = isPaused
                ? NSColor.secondaryLabelColor
                : NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.25, alpha: 0.7) // Warm gold
            playedColor.setStroke()
            playedPath.stroke()
        }

        // 4. Draw stylus / tape-head indicator marker
        let stylusHeadRadius: CGFloat = 2.5
        let stylusColor = isPaused
            ? NSColor.secondaryLabelColor
            : NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0) // Bright golden stylus

        // Vertical tape-head needle
        let needlePath = NSBezierPath()
        needlePath.move(to: NSPoint(x: stylusX, y: 0))
        needlePath.line(to: NSPoint(x: stylusX, y: height))
        needlePath.lineWidth = 2.0
        stylusColor.setStroke()
        needlePath.stroke()

        // Stylus head dot
        let dotRect = NSRect(
            x: stylusX - stylusHeadRadius,
            y: midY - stylusHeadRadius,
            width: stylusHeadRadius * 2,
            height: stylusHeadRadius * 2
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)
        stylusColor.setFill()
        dotPath.fill()
    }
}
