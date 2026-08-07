//
//  LirikPreferenceViewController.swift
//  lirik
//
//  Preference view controller for Lirik widget in Pock's Widgets Manager.
//  Conforms to PockKit's PKWidgetPreference protocol.
//

import Foundation
import AppKit
import PockKit

@objc(LirikPreferenceViewController)
final class LirikPreferenceViewController: NSViewController, PKWidgetPreference {

    static var nibName: NSNib.Name = NSNib.Name("LirikPreferenceViewController")

    convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - UserDefault Keys

    static let keyDualLine = "io.github.ridhaaf.lirik.dualLine"
    static let keyFontSize = "io.github.ridhaaf.lirik.fontSize"
    static let keyPreferredPlayer = "io.github.ridhaaf.lirik.preferredPlayer"
    static let keyShowPauseIcon = "io.github.ridhaaf.lirik.showPauseIcon"
    static let keyHighlightColor = "io.github.ridhaaf.lirik.highlightColor"
    static let keyAlignment = "io.github.ridhaaf.lirik.alignment"
    static let keyEnableMarquee = "io.github.ridhaaf.lirik.enableMarquee"
    static let keyShowAlbumArt = "io.github.ridhaaf.lirik.showAlbumArt"
    static let keyAlbumArtSize = "io.github.ridhaaf.lirik.albumArtSize"
    static let keyShowTrackInfo = "io.github.ridhaaf.lirik.showTrackInfo"

    // MARK: - UI Controls

    private let dualLineControl = NSSegmentedControl(labels: ["2-Line Karaoke", "1-Line Compact"], trackingMode: .selectOne, target: nil, action: nil)
    private let fontSizeControl = NSSegmentedControl(labels: ["Small (10pt)", "Medium (11pt)", "Large (12pt)"], trackingMode: .selectOne, target: nil, action: nil)
    private let colorControl = NSSegmentedControl(labels: ["White", "Gold", "Cyan", "Green", "Purple", "Pink", "Orange", "Red"], trackingMode: .selectOne, target: nil, action: nil)
    private let alignmentControl = NSSegmentedControl(labels: ["Left Aligned", "Center Aligned"], trackingMode: .selectOne, target: nil, action: nil)
    private let playerPopUp = NSPopUpButton()
    private let pauseIconCheckbox = NSButton(checkboxWithTitle: "Show ⏸ icon when track is paused", target: nil, action: nil)
    private let marqueeCheckbox = NSButton(checkboxWithTitle: "Enable marquee scrolling for long lyric lines", target: nil, action: nil)
    private let albumArtCheckbox = NSButton(checkboxWithTitle: "Show album artwork thumbnail", target: nil, action: nil)
    private let albumArtSizeControl = NSSegmentedControl(labels: ["Small", "Medium", "Large"], trackingMode: .selectOne, target: nil, action: nil)
    private let trackInfoCheckbox = NSButton(checkboxWithTitle: "Show Artist — Title when track changes", target: nil, action: nil)
    private let clearCacheButton = NSButton(title: "Clear Cached Lyrics", target: nil, action: nil)
    private let cacheStatusLabel = NSTextField(labelWithString: "")

    private let lyricsCache = LyricsCache()

    override func loadView() {
        let mainStackView = NSStackView()
        mainStackView.orientation = .vertical
        mainStackView.alignment = .leading
        mainStackView.spacing = 14
        mainStackView.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)

        // Title Header
        let titleLabel = NSTextField(labelWithString: "Lirik Preferences")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 15)
        mainStackView.addArrangedSubview(titleLabel)

        // 1. Display Mode (2-Line vs 1-Line)
        let modeStackView = NSStackView()
        modeStackView.orientation = .vertical
        modeStackView.alignment = .leading
        modeStackView.spacing = 4
        let modeTitle = NSTextField(labelWithString: "Display Mode:")
        modeTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modeStackView.addArrangedSubview(modeTitle)
        modeStackView.addArrangedSubview(dualLineControl)
        mainStackView.addArrangedSubview(modeStackView)

        // 2. Alignment
        let alignStackView = NSStackView()
        alignStackView.orientation = .vertical
        alignStackView.alignment = .leading
        alignStackView.spacing = 4
        let alignTitle = NSTextField(labelWithString: "Text Alignment:")
        alignTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        alignStackView.addArrangedSubview(alignTitle)
        alignStackView.addArrangedSubview(alignmentControl)
        mainStackView.addArrangedSubview(alignStackView)

        // 3. Font Size
        let fontStackView = NSStackView()
        fontStackView.orientation = .vertical
        fontStackView.alignment = .leading
        fontStackView.spacing = 4
        let fontTitle = NSTextField(labelWithString: "Lyric Text Size:")
        fontTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fontStackView.addArrangedSubview(fontTitle)
        fontStackView.addArrangedSubview(fontSizeControl)
        mainStackView.addArrangedSubview(fontStackView)

        // 4. Highlight Color
        let colorStackView = NSStackView()
        colorStackView.orientation = .vertical
        colorStackView.alignment = .leading
        colorStackView.spacing = 4
        let colorTitle = NSTextField(labelWithString: "Lyric Highlight Color:")
        colorTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        colorStackView.addArrangedSubview(colorTitle)
        colorStackView.addArrangedSubview(colorControl)
        mainStackView.addArrangedSubview(colorStackView)

        // 5. Preferred Player
        let playerStackView = NSStackView()
        playerStackView.orientation = .vertical
        playerStackView.alignment = .leading
        playerStackView.spacing = 4
        let playerTitle = NSTextField(labelWithString: "Music Player Source:")
        playerTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        playerStackView.addArrangedSubview(playerTitle)

        playerPopUp.addItems(withTitles: ["Auto-detect (Spotify priority)", "Spotify Only", "Apple Music Only"])
        playerStackView.addArrangedSubview(playerPopUp)
        mainStackView.addArrangedSubview(playerStackView)

        // 6. Checkboxes (Pause Indicator, Marquee Scrolling, Album Art, Track Info)
        mainStackView.addArrangedSubview(pauseIconCheckbox)
        mainStackView.addArrangedSubview(marqueeCheckbox)
        mainStackView.addArrangedSubview(albumArtCheckbox)

        // Album Art Size
        let artSizeStackView = NSStackView()
        artSizeStackView.orientation = .vertical
        artSizeStackView.alignment = .leading
        artSizeStackView.spacing = 4
        let artSizeTitle = NSTextField(labelWithString: "Album Art Size:")
        artSizeTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        artSizeStackView.addArrangedSubview(artSizeTitle)
        artSizeStackView.addArrangedSubview(albumArtSizeControl)
        mainStackView.addArrangedSubview(artSizeStackView)

        mainStackView.addArrangedSubview(trackInfoCheckbox)

        // 7. Clear Cache Button
        let cacheStackView = NSStackView()
        cacheStackView.orientation = .horizontal
        cacheStackView.alignment = .centerY
        cacheStackView.spacing = 8
        clearCacheButton.bezelStyle = .rounded
        clearCacheButton.target = self
        clearCacheButton.action = #selector(onClearCacheTapped)
        cacheStatusLabel.font = NSFont.systemFont(ofSize: 11)
        cacheStatusLabel.textColor = .secondaryLabelColor
        cacheStackView.addArrangedSubview(clearCacheButton)
        cacheStackView.addArrangedSubview(cacheStatusLabel)
        mainStackView.addArrangedSubview(cacheStackView)

        // Target actions
        dualLineControl.target = self
        dualLineControl.action = #selector(onDualLineChanged)

        alignmentControl.target = self
        alignmentControl.action = #selector(onAlignmentChanged)

        fontSizeControl.target = self
        fontSizeControl.action = #selector(onFontSizeChanged)

        colorControl.target = self
        colorControl.action = #selector(onColorChanged)

        playerPopUp.target = self
        playerPopUp.action = #selector(onPlayerChanged)

        pauseIconCheckbox.target = self
        pauseIconCheckbox.action = #selector(onPauseCheckboxChanged)

        marqueeCheckbox.target = self
        marqueeCheckbox.action = #selector(onMarqueeCheckboxChanged)

        albumArtCheckbox.target = self
        albumArtCheckbox.action = #selector(onAlbumArtCheckboxChanged)

        albumArtSizeControl.target = self
        albumArtSizeControl.action = #selector(onAlbumArtSizeChanged)

        trackInfoCheckbox.target = self
        trackInfoCheckbox.action = #selector(onTrackInfoCheckboxChanged)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 520))
        mainStackView.frame = container.bounds
        mainStackView.autoresizingMask = [.width, .height]
        container.addSubview(mainStackView)

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadSavedPreferences()
    }

    private func loadSavedPreferences() {
        let defaults = UserDefaults.standard
        let dualLine = defaults.object(forKey: Self.keyDualLine) as? Bool ?? true
        dualLineControl.selectedSegment = dualLine ? 0 : 1

        let align = defaults.string(forKey: Self.keyAlignment) ?? "left"
        alignmentControl.selectedSegment = align == "center" ? 1 : 0

        let fontSize = defaults.object(forKey: Self.keyFontSize) as? Int ?? 11
        if fontSize <= 10 {
            fontSizeControl.selectedSegment = 0
        } else if fontSize >= 12 {
            fontSizeControl.selectedSegment = 2
        } else {
            fontSizeControl.selectedSegment = 1
        }

        let color = defaults.string(forKey: Self.keyHighlightColor) ?? "white"
        switch color {
        case "gold": colorControl.selectedSegment = 1
        case "cyan": colorControl.selectedSegment = 2
        case "green": colorControl.selectedSegment = 3
        case "purple": colorControl.selectedSegment = 4
        case "pink": colorControl.selectedSegment = 5
        case "orange": colorControl.selectedSegment = 6
        case "red": colorControl.selectedSegment = 7
        default: colorControl.selectedSegment = 0
        }

        let player = defaults.string(forKey: Self.keyPreferredPlayer) ?? "auto"
        if player == "spotify" {
            playerPopUp.selectItem(at: 1)
        } else if player == "music" {
            playerPopUp.selectItem(at: 2)
        } else {
            playerPopUp.selectItem(at: 0)
        }

        let showPause = defaults.object(forKey: Self.keyShowPauseIcon) as? Bool ?? true
        pauseIconCheckbox.state = showPause ? .on : .off

        let marquee = defaults.object(forKey: Self.keyEnableMarquee) as? Bool ?? true
        marqueeCheckbox.state = marquee ? .on : .off

        let showArt = defaults.object(forKey: Self.keyShowAlbumArt) as? Bool ?? true
        albumArtCheckbox.state = showArt ? .on : .off

        let artSize = defaults.object(forKey: Self.keyAlbumArtSize) as? Int ?? 1
        albumArtSizeControl.selectedSegment = artSize

        let showTrackInfo = defaults.object(forKey: Self.keyShowTrackInfo) as? Bool ?? true
        trackInfoCheckbox.state = showTrackInfo ? .on : .off
    }

    @objc private func onDualLineChanged() {
        let dualLine = dualLineControl.selectedSegment == 0
        UserDefaults.standard.set(dualLine, forKey: Self.keyDualLine)
    }

    @objc private func onAlignmentChanged() {
        let align = alignmentControl.selectedSegment == 1 ? "center" : "left"
        UserDefaults.standard.set(align, forKey: Self.keyAlignment)
    }

    @objc private func onFontSizeChanged() {
        let size: Int
        switch fontSizeControl.selectedSegment {
        case 0: size = 10
        case 2: size = 12
        default: size = 11
        }
        UserDefaults.standard.set(size, forKey: Self.keyFontSize)
    }

    @objc private func onColorChanged() {
        let color: String
        switch colorControl.selectedSegment {
        case 1: color = "gold"
        case 2: color = "cyan"
        case 3: color = "green"
        case 4: color = "purple"
        case 5: color = "pink"
        case 6: color = "orange"
        case 7: color = "red"
        default: color = "white"
        }
        UserDefaults.standard.set(color, forKey: Self.keyHighlightColor)
    }

    @objc private func onPlayerChanged() {
        let player: String
        switch playerPopUp.indexOfSelectedItem {
        case 1: player = "spotify"
        case 2: player = "music"
        default: player = "auto"
        }
        UserDefaults.standard.set(player, forKey: Self.keyPreferredPlayer)
    }

    @objc private func onPauseCheckboxChanged() {
        let showPause = pauseIconCheckbox.state == .on
        UserDefaults.standard.set(showPause, forKey: Self.keyShowPauseIcon)
    }

    @objc private func onMarqueeCheckboxChanged() {
        let marquee = marqueeCheckbox.state == .on
        UserDefaults.standard.set(marquee, forKey: Self.keyEnableMarquee)
    }

    @objc private func onAlbumArtCheckboxChanged() {
        let showArt = albumArtCheckbox.state == .on
        UserDefaults.standard.set(showArt, forKey: Self.keyShowAlbumArt)
    }

    @objc private func onAlbumArtSizeChanged() {
        UserDefaults.standard.set(albumArtSizeControl.selectedSegment, forKey: Self.keyAlbumArtSize)
    }

    @objc private func onTrackInfoCheckboxChanged() {
        let showTrackInfo = trackInfoCheckbox.state == .on
        UserDefaults.standard.set(showTrackInfo, forKey: Self.keyShowTrackInfo)
    }

    @objc private func onClearCacheTapped() {
        lyricsCache.clear()
        cacheStatusLabel.stringValue = "✓ Cache Cleared"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.cacheStatusLabel.stringValue = ""
        }
    }

    func reset() {
        UserDefaults.standard.set(true, forKey: Self.keyDualLine)
        UserDefaults.standard.set(11, forKey: Self.keyFontSize)
        UserDefaults.standard.set("auto", forKey: Self.keyPreferredPlayer)
        UserDefaults.standard.set(true, forKey: Self.keyShowPauseIcon)
        UserDefaults.standard.set(true, forKey: Self.keyEnableMarquee)
        UserDefaults.standard.set(true, forKey: Self.keyShowAlbumArt)
        UserDefaults.standard.set(1, forKey: Self.keyAlbumArtSize) // Medium default
        UserDefaults.standard.set(true, forKey: Self.keyShowTrackInfo)
        UserDefaults.standard.set("white", forKey: Self.keyHighlightColor)
        UserDefaults.standard.set("left", forKey: Self.keyAlignment)
        loadSavedPreferences()
    }
}
