//
//  LirikWidget.swift
//  lirik
//
//  Principal entry point for PockKit bundle loading (`NSPrincipalClass` in Info.plist).
//  Subclasses / wraps `LyricsWidget` for Pock host discovery.
//

import Foundation
import AppKit
import PockKit

@objc(LirikWidget)
class LirikWidget: LyricsWidget {
    // Inherits all PKWidget functionality, rendering, and lifecycle from LyricsWidget
}
