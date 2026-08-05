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

@objc (LirikPreferenceViewController)
final class LirikPreferenceViewController: NSViewController, PKWidgetPreference {

    static var nibName: NSNib.Name = NSNib.Name("LirikPreferenceViewController")

    // MARK: - UserDefault Keys

    static let keyDualLine = "io.github.ridhaaf.lirik.dualLine"
    static let keyFontSize = "io.github.ridhaaf.lirik.fontSize"
    static let keyPreferredPlayer = "io.github.ridhaaf.lirik.preferredPlayer"
    static let keyShowPauseIcon = "io.github.ridhaaf.lirik.showPauseIcon"

    // MARK: - UI Controls

    private let dualLineControl = NSSegmentedControl(labels: ["2-Line Karaoke", "1-Line Compact"], trackingMode: .selectOne, target: nil, action: nil)
    private let fontSizeControl = NSSegmentedControl(labels: ["Small (10pt)", "Medium (11pt)", "Large (12pt)"], trackingMode: .selectOne, target: nil, action: nil)
    private let playerPopUp = NSPopUpButton()
    private let pauseIconCheckbox = NSButton(checkboxWithTitle: "Show ⏸ icon when track is paused", target: nil, action: nil)

    override func loadView() {
        let mainStackView = NSStackView()
        mainStackView.orientation = .vertical
        mainStackView.alignment = .leading
        mainStackView.spacing = 16
        mainStackView.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

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

        // 2. Font Size
        let fontStackView = NSStackView()
        fontStackView.orientation = .vertical
        fontStackView.alignment = .leading
        fontStackView.spacing = 4
        let fontTitle = NSTextField(labelWithString: "Lyric Text Size:")
        fontTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fontStackView.addArrangedSubview(fontTitle)
        fontStackView.addArrangedSubview(fontSizeControl)
        mainStackView.addArrangedSubview(fontStackView)

        // 3. Preferred Player
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

        // 4. Pause Indicator Checkbox
        mainStackView.addArrangedSubview(pauseIconCheckbox)

        // Target actions
        dualLineControl.target = self
        dualLineControl.action = #selector(onDualLineChanged)

        fontSizeControl.target = self
        fontSizeControl.action = #selector(onFontSizeChanged)

        playerPopUp.target = self
        playerPopUp.action = #selector(onPlayerChanged)

        pauseIconCheckbox.target = self
        pauseIconCheckbox.action = #selector(onPauseCheckboxChanged)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
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

        let fontSize = defaults.object(forKey: Self.keyFontSize) as? Int ?? 11
        if fontSize <= 10 {
            fontSizeControl.selectedSegment = 0
        } else if fontSize >= 12 {
            fontSizeControl.selectedSegment = 2
        } else {
            fontSizeControl.selectedSegment = 1
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
    }

    @objc private func onDualLineChanged() {
        let dualLine = dualLineControl.selectedSegment == 0
        UserDefaults.standard.set(dualLine, forKey: Self.keyDualLine)
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

    func reset() {
        UserDefaults.standard.set(true, forKey: Self.keyDualLine)
        UserDefaults.standard.set(11, forKey: Self.keyFontSize)
        UserDefaults.standard.set("auto", forKey: Self.keyPreferredPlayer)
        UserDefaults.standard.set(true, forKey: Self.keyShowPauseIcon)
        loadSavedPreferences()
    }
}
