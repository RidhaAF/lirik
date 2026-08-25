//
//  LyricsWidget.swift
//  lirik
//
//  Touch Bar widget rendering real-time synced lyrics.
//  Conforms to PockKit's PKWidget protocol.
//
//  Per AGENTS.md §8: Contains rendering logic ONLY.
//  Reads state produced by NowPlayingWatcher, LRCLIBClient, LyricsCache, and LRCSyncEngine.
//

import Foundation
import AppKit
import PockKit

/// UI Display State for the Lyrics Touch Bar widget.
enum LyricsWidgetUIState: Equatable {
    case noTrackPlaying
    case permissionDenied(appName: String)
    case loading(title: String, artist: String)
    case noLyricsFound(title: String, artist: String)
    case staticOnly(title: String, artist: String, text: String)
    case synced(title: String, artist: String, lines: [LRCLine])
}

class LyricsWidget: NSObject, PKWidget {

    // MARK: - PKWidget Protocol Properties

    static var identifier: String = "io.github.ridhaaf.lirik"
    var customizationLabel: String = "Lirik - Synced Lyrics"
    var view: NSView!

    var imageForCustomization: NSImage {
        let size = NSSize(width: 60, height: 20)
        let image = NSImage(size: size)
        image.lockFocus()

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        if let rawIcon = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let tintedIcon = NSImage(size: NSSize(width: 16, height: 16))
            tintedIcon.lockFocus()
            NSColor.labelColor.set()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            rawIcon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16), from: .zero, operation: .destinationIn, fraction: 1.0)
            tintedIcon.unlockFocus()

            tintedIcon.draw(in: NSRect(x: 0, y: 2, width: 16, height: 16))
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        NSString("Lirik").draw(at: NSPoint(x: 20, y: 2), withAttributes: attrs)

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - PKWidgetPreference link for Pock Widgets Manager

    @objc var hasPreferencesView: Bool { return true }
    @objc var preferenceClass: PKWidgetPreference.Type? { return LirikPreferenceViewController.self }
    @objc var preferenceView: PKWidgetPreference? { return LirikPreferenceViewController() }
    @objc var preferences: PKWidgetPreference? { return LirikPreferenceViewController() }

    // MARK: - UI Components

    private let containerView = NSStackView()
    private let contentStackView = NSStackView()
    private let textStackView = NSStackView()
    private let tapButton = PKButton(title: "", target: nil, action: nil)

    private let currentLineLabel = NSTextField(labelWithString: "Lirik")
    private let nextLineLabel = NSTextField(labelWithString: "")

    /// Album cover art thumbnail (configurable size, rounded corners)
    private let albumArtImageView = NSImageView()
    private var albumArtWidthConstraint: NSLayoutConstraint?
    private var albumArtHeightConstraint: NSLayoutConstraint?

    /// Previous current-line text, used to detect changes for fade animation.
    private var previousCurrentLineText: String = ""

    /// Track info display: shows "Artist — Title" briefly when track changes.
    /// nil if not showing. Set to Date() + 3s on track change.
    private var trackInfoVisibleUntil: Date?

    // MARK: - Logic Dependencies

    private let nowPlayingWatcher = NowPlayingWatcher()
    private let lrclibClient = LRCLIBClient()
    private let lyricsCache = LyricsCache()
    private let albumArtService = AlbumArtService()

    // MARK: - Widget State & Race Condition Fencing

    private var activeTrackKey: String = ""
    private var inFlightFetchTask: Task<Void, Never>?

    private var uiState: LyricsWidgetUIState = .noTrackPlaying {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.updateUI()
            }
        }
    }

    private var activeLines: [LRCLine] = []
    private var isCurrentlyPaused: Bool = false

    // MARK: - Init

    required override init() {
        super.init()
        setupUI()
        setupWatcherCallbacks()
        observePreferenceChanges()
        observeSystemWakeAndVisibility()
        // Ensure watcher starts watching immediately upon initialization
        nowPlayingWatcher.startWatching()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - PKWidget Lifecycle Hooks

    func viewAppeared() {
        NSLog("[LyricsWidget] viewAppeared — starting NowPlayingWatcher + forcing refresh")
        nowPlayingWatcher.startWatching()
        // Whenever the widget comes back into view (Touch Bar wake, DFR resume,
        // app switch, etc.) force a fresh poll so we don't render stale state.
        nowPlayingWatcher.forceRefresh()
        // Also re-render current state so any UI derived from stale elapsed
        // time recomputes against the freshest snapshot.
        DispatchQueue.main.async { [weak self] in self?.updateUI() }
    }

    func viewDisappeared() {
        NSLog("[LyricsWidget] viewDisappeared — stopping NowPlayingWatcher")
        inFlightFetchTask?.cancel()
        nowPlayingWatcher.stopWatching()
    }

    // MARK: - System wake / Touch Bar wake handling

    /// Observes system + Touch Bar wake and app-activation events so we can
    /// force-refresh the now-playing snapshot the instant the widget becomes
    /// user-visible again. Fixes the "lyrics frozen after Touch Bar goes to
    /// sleep" symptom: even with `.common`-mode timers, timer firings can
    /// coalesce or MediaRemote snapshots stay stale across a DFR sleep, so
    /// we need an explicit "wake → refresh" edge.
    private func observeSystemWakeAndVisibility() {
        let ws = NSWorkspace.shared.notificationCenter

        // System wake from sleep (lid open, power button, etc.)
        ws.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Screen wake (Touch Bar comes back on when the display wakes)
        ws.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        // Session became active (fast user switching back to us)
        ws.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        // App activation — proxy for "user is back at the machine"
        ws.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func handleSystemDidWake(_ note: Notification) {
        NSLog("[LyricsWidget] Wake/activation event (\(note.name.rawValue)) — forcing refresh")
        nowPlayingWatcher.forceRefresh()
        DispatchQueue.main.async { [weak self] in self?.updateUI() }
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Album art image view (24x24, rounded corners, left of text)
        albumArtImageView.imageScaling = .scaleProportionallyUpOrDown
        albumArtImageView.wantsLayer = true
        albumArtImageView.layer?.cornerRadius = 4
        albumArtImageView.layer?.masksToBounds = true
        albumArtImageView.setContentHuggingPriority(.required, for: .horizontal)
        albumArtImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        albumArtWidthConstraint = albumArtImageView.widthAnchor.constraint(equalToConstant: 24)
        albumArtHeightConstraint = albumArtImageView.heightAnchor.constraint(equalToConstant: 24)
        albumArtWidthConstraint?.isActive = true
        albumArtHeightConstraint?.isActive = true
        albumArtImageView.isHidden = true // Hidden until artwork loads

        // Container stack view (horizontal: album art + text)
        containerView.orientation = .horizontal
        containerView.alignment = .centerY
        containerView.distribution = .fill
        containerView.spacing = 4
        containerView.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 4)

        // Content stack view (vertical: text stack)
        contentStackView.orientation = .vertical
        contentStackView.alignment = .leading
        contentStackView.distribution = .fill
        contentStackView.spacing = 1

        // Text stack view (vertical: current line + next line)
        textStackView.orientation = .vertical
        textStackView.alignment = .leading
        textStackView.distribution = .fillProportionally
        textStackView.spacing = 0

        // Current line label (bold 11pt for Touch Bar karaoke primary line)
        currentLineLabel.font = NSFont.boldSystemFont(ofSize: 11)
        currentLineLabel.textColor = .labelColor
        currentLineLabel.lineBreakMode = .byTruncatingTail
        currentLineLabel.stringValue = "Lirik"
        currentLineLabel.wantsLayer = true

        // Next line label (dimmed 9pt for Touch Bar karaoke secondary line)
        nextLineLabel.font = NSFont.systemFont(ofSize: 9)
        nextLineLabel.wantsLayer = true
        nextLineLabel.textColor = .secondaryLabelColor
        nextLineLabel.lineBreakMode = .byTruncatingTail
        nextLineLabel.stringValue = ""

        textStackView.addArrangedSubview(currentLineLabel)
        textStackView.addArrangedSubview(nextLineLabel)

        contentStackView.addArrangedSubview(textStackView)

        // Configure native Touch Bar PKButton wrapper for tap-to-copy
        tapButton.target = self
        tapButton.action = #selector(handleTouchBarTap)
        tapButton.title = ""
        tapButton.isBordered = false
        tapButton.addSubview(contentStackView)

        // Layout contentStackView to fill tapButton bounds
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStackView.leadingAnchor.constraint(equalTo: tapButton.leadingAnchor),
            contentStackView.trailingAnchor.constraint(equalTo: tapButton.trailingAnchor),
            contentStackView.topAnchor.constraint(equalTo: tapButton.topAnchor),
            contentStackView.bottomAnchor.constraint(equalTo: tapButton.bottomAnchor)
        ])

        containerView.addArrangedSubview(albumArtImageView)
        containerView.addArrangedSubview(tapButton)

        // Prevent widget from resizing when lyrics change length
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        self.view = containerView
    }

    // MARK: - Touch Bar Tap Gesture Handler

    @objc private func handleTouchBarTap() {
        let textToCopy = currentLineLabel.stringValue.replacingOccurrences(of: "⏸ ", with: "").trimmingCharacters(in: .whitespaces)
        guard !textToCopy.isEmpty,
              textToCopy != "Lirik",
              textToCopy != "Fetching lyrics...",
              textToCopy != "No track playing",
              textToCopy != "No synced lyrics available",
              textToCopy != "📋 Copied!" else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textToCopy, forType: .string)

        let previousText = currentLineLabel.stringValue
        currentLineLabel.stringValue = "📋 Copied to Clipboard!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            if self.currentLineLabel.stringValue == "📋 Copied to Clipboard!" {
                self.currentLineLabel.stringValue = previousText
            }
        }
    }

    // MARK: - Watcher Callbacks

    private func setupWatcherCallbacks() {
        // Handle permission error notification
        nowPlayingWatcher.onPermissionDenied = { [weak self] appName in
            self?.uiState = .permissionDenied(appName: appName)
        }

        // Handle track changes & rapid skipping
        nowPlayingWatcher.onTrackChange = { [weak self] track in
            guard let self else { return }

            // Cancel any in-flight fetch task from previous track immediately
            self.inFlightFetchTask?.cancel()

            if let track = track {
                self.isCurrentlyPaused = !track.isPlaying
                let newKey = LyricsCache.makeTrackKey(title: track.title, artist: track.artist, duration: track.duration)
                self.activeTrackKey = newKey

                // Show track info briefly if enabled
                let defaults = UserDefaults.standard
                if defaults.object(forKey: LirikPreferenceViewController.keyShowTrackInfo) as? Bool ?? false {
                    self.trackInfoVisibleUntil = Date().addingTimeInterval(3.0)
                }

                self.loadLyrics(for: track, expectedKey: newKey, forceRefresh: false)
                self.fetchAlbumArt(for: track)
            } else {
                self.activeTrackKey = ""
                self.activeLines = []
                self.isCurrentlyPaused = false
                self.uiState = .noTrackPlaying
            }
        }

        // Handle elapsed time ticks for synced & static lyrics
        nowPlayingWatcher.onElapsedTimeUpdate = { [weak self] elapsed in
            guard let self else { return }

            guard let track = self.nowPlayingWatcher.currentTrack else { return }

            DispatchQueue.main.async {
                self.isCurrentlyPaused = !track.isPlaying

                if case .synced(_, _, let lines) = self.uiState {
                    let snapshot = LRCSyncEngine.resolve(elapsedTime: elapsed, lines: lines)
                    self.renderSyncSnapshot(snapshot, isPaused: !track.isPlaying)
                } else if case .staticOnly(_, _, let text) = self.uiState {
                    self.renderStaticLyrics(text, elapsed: elapsed, trackDuration: track.duration, isPaused: !track.isPlaying)
                }
            }
        }
    }

    // MARK: - Preference Change Observers

    /// Observes realtime preference changes (e.g. album art toggle) to update the widget immediately
    /// without waiting for the next track change.
    private func observePreferenceChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAlbumArtPreferenceChanged),
            name: Notification.Name("io.github.ridhaaf.lirik.albumArtChanged"),
            object: nil
        )
    }

    @objc private func onAlbumArtPreferenceChanged() {
        let defaults = UserDefaults.standard
        let showArt = defaults.object(forKey: LirikPreferenceViewController.keyShowAlbumArt) as? Bool ?? false

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if showArt {
                // Re-fetch artwork for the current track
                if let track = self.nowPlayingWatcher.currentTrack {
                    self.fetchAlbumArt(for: track)
                }
            } else {
                self.albumArtImageView.isHidden = true
            }
        }
    }

    // MARK: - Lyrics Loading & Caching Flow (Race Condition Fenced)

    private func loadLyrics(for track: NowPlayingTrack, expectedKey: String, forceRefresh: Bool) {
        uiState = .loading(title: track.title, artist: track.artist)

        // Step 1: Check cache unless forceRefresh is requested
        if !forceRefresh,
           let cached = lyricsCache.get(byKey: expectedKey) {
            // Guard against stale track key from rapid skipping
            guard activeTrackKey == expectedKey else { return }
            applyCachedLyrics(cached, for: track)
            return
        }

        // Step 2: Query LRCLIB REST API asynchronously with task cancellation support
        inFlightFetchTask = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await self.lrclibClient.fetchLyrics(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration
                )

                // FENCING CHECK: Cancel if task was cancelled or user skipped to a new track while fetching
                guard !Task.isCancelled, self.activeTrackKey == expectedKey else {
                    NSLog("[LyricsWidget] Ignored stale lyrics fetch for key: \(expectedKey)")
                    return
                }

                let cachedEntry: CachedLyrics
                let newState: LyricsWidgetUIState

                switch result {
                case .synced(let id, let lrcText, _):
                    let parsedLines = LRCParser.parse(lrcText)
                    cachedEntry = CachedLyrics(
                        lrclibID: id,
                        trackKey: expectedKey,
                        lyricsState: .synced(lines: parsedLines, rawLRC: lrcText),
                        cachedAt: Date()
                    )
                    newState = .synced(title: track.title, artist: track.artist, lines: parsedLines)
                    self.activeLines = parsedLines

                case .plainOnly(let id, let plainText):
                    cachedEntry = CachedLyrics(
                        lrclibID: id,
                        trackKey: expectedKey,
                        lyricsState: .plainOnly(text: plainText),
                        cachedAt: Date()
                    )
                    newState = .staticOnly(title: track.title, artist: track.artist, text: plainText)
                    self.activeLines = []

                case .notFound:
                    cachedEntry = CachedLyrics(
                        lrclibID: nil,
                        trackKey: expectedKey,
                        lyricsState: .notFound,
                        cachedAt: Date()
                    )
                    newState = .noLyricsFound(title: track.title, artist: track.artist)
                    self.activeLines = []
                }

                // Final check before committing state
                guard !Task.isCancelled, self.activeTrackKey == expectedKey else { return }
                self.lyricsCache.save(cachedEntry)
                self.uiState = newState

            } catch {
                guard !Task.isCancelled, self.activeTrackKey == expectedKey else { return }
                NSLog("[LyricsWidget] Network error loading lyrics: \(error.localizedDescription)")
                self.uiState = .noLyricsFound(title: track.title, artist: track.artist)
            }
        }
    }

    private func applyCachedLyrics(_ cached: CachedLyrics, for track: NowPlayingTrack) {
        switch cached.lyricsState {
        case .synced(let lines, _):
            activeLines = lines
            uiState = .synced(title: track.title, artist: track.artist, lines: lines)
        case .plainOnly(let text):
            activeLines = []
            uiState = .staticOnly(title: track.title, artist: track.artist, text: text)
        case .notFound:
            activeLines = []
            uiState = .noLyricsFound(title: track.title, artist: track.artist)
        }
    }

    // MARK: - UI Rendering

    private func updateUI() {
        switch uiState {
        case .noTrackPlaying:
            currentLineLabel.stringValue = "Lirik"
            currentLineLabel.textColor = .secondaryLabelColor
            nextLineLabel.stringValue = "No track playing"
            albumArtImageView.isHidden = true

        case .permissionDenied(let appName):
            currentLineLabel.stringValue = "Permission Required"
            currentLineLabel.textColor = .systemRed
            nextLineLabel.stringValue = "Allow Pock -> \(appName) in System Settings"
            albumArtImageView.isHidden = true

        case .loading:
            currentLineLabel.stringValue = "Fetching lyrics..."
            currentLineLabel.textColor = .labelColor
            nextLineLabel.stringValue = ""

        case .noLyricsFound:
            currentLineLabel.stringValue = "No lyrics available"
            currentLineLabel.textColor = .secondaryLabelColor
            nextLineLabel.stringValue = ""

        case .staticOnly(_, _, let text):
            let elapsed = nowPlayingWatcher.currentTrack?.elapsedTime ?? 0
            let duration = nowPlayingWatcher.currentTrack?.duration
            renderStaticLyrics(text, elapsed: elapsed, trackDuration: duration, isPaused: isCurrentlyPaused)

        case .synced(_, _, let lines):
            if lines.isEmpty {
                currentLineLabel.stringValue = "No lyrics text"
                currentLineLabel.textColor = .secondaryLabelColor
                nextLineLabel.stringValue = ""
            } else {
                let elapsed = nowPlayingWatcher.currentTrack?.elapsedTime ?? 0
                let snapshot = LRCSyncEngine.resolve(elapsedTime: elapsed, lines: lines)
                renderSyncSnapshot(snapshot, isPaused: isCurrentlyPaused)
            }
        }
    }

    private func resolveHighlightColor(isPaused: Bool) -> NSColor {
        guard !isPaused else { return .secondaryLabelColor }
        let defaults = UserDefaults.standard
        let colorKey = defaults.string(forKey: LirikPreferenceViewController.keyHighlightColor) ?? "white"
        switch colorKey {
        case "gold": return NSColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
        case "cyan": return NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0)
        case "green": return NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        case "purple": return NSColor(red: 0.75, green: 0.45, blue: 1.0, alpha: 1.0)
        case "pink": return NSColor(red: 1.0, green: 0.4, blue: 0.7, alpha: 1.0)
        case "orange": return NSColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)
        case "red": return NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
        default: return .labelColor
        }
    }

    private func applyTextAlignment() {
        let defaults = UserDefaults.standard
        let alignKey = defaults.string(forKey: LirikPreferenceViewController.keyAlignment) ?? "left"
        let isCenter = alignKey == "center"

        textStackView.alignment = isCenter ? .centerX : .leading
        currentLineLabel.alignment = isCenter ? .center : .left
        nextLineLabel.alignment = isCenter ? .center : .left
    }

    private func formatLineText(_ text: String) -> String {
        let defaults = UserDefaults.standard
        let enableMarquee = defaults.object(forKey: LirikPreferenceViewController.keyEnableMarquee) as? Bool ?? false

        guard enableMarquee, text.count > 42 else { return text }

        let timeOffset = Int(Date().timeIntervalSince1970 * 2) % (text.count + 6)
        let extended = text + "  •  " + text
        let start = extended.index(extended.startIndex, offsetBy: min(timeOffset, extended.count - 1))
        let end = extended.index(start, offsetBy: min(38, extended.distance(from: start, to: extended.endIndex)))
        return String(extended[start..<end])
    }

    private func renderStaticLyrics(_ text: String, elapsed: TimeInterval, trackDuration: TimeInterval?, isPaused: Bool) {
        // If track info is still visible, show it instead of lyrics (karaoke style: title on top, artist below)
        if let (title, artist) = trackInfoComponents() {
            currentLineLabel.stringValue = title
            currentLineLabel.textColor = resolveHighlightColor(isPaused: false)
            currentLineLabel.font = NSFont.boldSystemFont(ofSize: 11)
            nextLineLabel.stringValue = artist
            nextLineLabel.font = NSFont.systemFont(ofSize: 9)
            nextLineLabel.textColor = .secondaryLabelColor
            nextLineLabel.isHidden = false
            return
        }

        let defaults = UserDefaults.standard
        let dualLine = defaults.object(forKey: LirikPreferenceViewController.keyDualLine) as? Bool ?? true
        let fontSize = defaults.object(forKey: LirikPreferenceViewController.keyFontSize) as? Int ?? 11
        let showPauseIcon = defaults.object(forKey: LirikPreferenceViewController.keyShowPauseIcon) as? Bool ?? true

        applyTextAlignment()
        currentLineLabel.font = NSFont.boldSystemFont(ofSize: CGFloat(fontSize))
        nextLineLabel.font = NSFont.systemFont(ofSize: CGFloat(max(8, fontSize - 2)))
        nextLineLabel.isHidden = !dualLine

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            currentLineLabel.stringValue = "Static lyrics"
            currentLineLabel.textColor = .secondaryLabelColor
            nextLineLabel.stringValue = ""
            return
        }

        let totalDuration = (trackDuration ?? 0) > 0 ? trackDuration! : 180.0
        let lineDuration = max(2.5, totalDuration / Double(lines.count))
        let currentIndex = min(lines.count - 1, max(0, Int(elapsed / lineDuration)))
        let nextIndex = currentIndex + 1 < lines.count ? currentIndex + 1 : nil

        applyAlbumArtSize()

        let prefix = (isPaused && showPauseIcon) ? "⏸ " : ""
        let newText = "\(prefix)\(formatLineText(lines[currentIndex]))"
        currentLineLabel.textColor = resolveHighlightColor(isPaused: isPaused)
        setLineText(currentLineLabel, newText)
        previousCurrentLineText = newText
        nextLineLabel.stringValue = nextIndex != nil ? lines[nextIndex!] : ""
    }

    private func renderSyncSnapshot(_ snapshot: LRCSyncSnapshot, isPaused: Bool) {
        // If track info is still visible, show it instead of lyrics (karaoke style: title on top, artist below)
        if let (title, artist) = trackInfoComponents() {
            currentLineLabel.textColor = resolveHighlightColor(isPaused: false)
            currentLineLabel.font = NSFont.boldSystemFont(ofSize: 11)
            currentLineLabel.stringValue = title
            nextLineLabel.stringValue = artist
            nextLineLabel.font = NSFont.systemFont(ofSize: 9)
            nextLineLabel.textColor = .secondaryLabelColor
            nextLineLabel.isHidden = false
            return
        }

        let defaults = UserDefaults.standard
        let dualLine = defaults.object(forKey: LirikPreferenceViewController.keyDualLine) as? Bool ?? true
        let fontSize = defaults.object(forKey: LirikPreferenceViewController.keyFontSize) as? Int ?? 11
        let showPauseIcon = defaults.object(forKey: LirikPreferenceViewController.keyShowPauseIcon) as? Bool ?? true

        applyTextAlignment()
        currentLineLabel.font = NSFont.boldSystemFont(ofSize: CGFloat(fontSize))
        nextLineLabel.font = NSFont.systemFont(ofSize: CGFloat(max(8, fontSize - 2)))
        nextLineLabel.isHidden = !dualLine

        applyAlbumArtSize()

        let prefix = (isPaused && showPauseIcon) ? "⏸ " : ""
        let activeColor = resolveHighlightColor(isPaused: isPaused)
        currentLineLabel.textColor = activeColor

        let newText: String
        let upcoming: String

        switch snapshot.positionState {
        case .empty:
            newText = ""
            upcoming = ""
        case .beforeFirstLine:
            newText = "\(prefix)\(formatLineText(snapshot.upcomingLine?.text ?? ""))"
            upcoming = activeLines.count > 1 ? activeLines[1].text : ""
        case .inLyrics:
            let text = snapshot.currentLine?.text.isEmpty == true
                ? "♪ (instrumental)"
                : snapshot.currentLine?.text ?? ""
            newText = "\(prefix)\(formatLineText(text))"
            upcoming = snapshot.upcomingLine?.text ?? ""
        case .afterLastLine:
            newText = "\(prefix)\(formatLineText(snapshot.currentLine?.text ?? ""))"
            upcoming = ""
        }

        setLineText(currentLineLabel, newText)
        previousCurrentLineText = newText
        nextLineLabel.stringValue = upcoming
    }

    // MARK: - Album Art Fetching

    /// Fetches album artwork for the given track and displays it in the thumbnail.
    /// Skips fetch if the "Show album artwork" preference is disabled.
    private func fetchAlbumArt(for track: NowPlayingTrack) {
        let defaults = UserDefaults.standard
        let showArt = defaults.object(forKey: LirikPreferenceViewController.keyShowAlbumArt) as? Bool ?? false
        guard showArt else {
            DispatchQueue.main.async { [weak self] in
                self?.albumArtImageView.isHidden = true
            }
            return
        }

        // Apply dynamic size from preferences
        applyAlbumArtSize()

        Task { [weak self] in
            guard let self else { return }

            let image = await self.albumArtService.fetchArtwork(
                artist: track.artist,
                album: track.album
            )

            // Guard against stale results (track may have changed during fetch)
            guard self.nowPlayingWatcher.currentTrack?.isSameTrack(as: track) == true else {
                return
            }

            DispatchQueue.main.async {
                if let image = image {
                    self.albumArtImageView.image = image
                    self.albumArtImageView.isHidden = false
                } else {
                    // No artwork found — show a music note placeholder
                    let placeholder = NSImage(
                        systemSymbolName: "music.note",
                        accessibilityDescription: "Album Art"
                    )
                    self.albumArtImageView.image = placeholder
                    self.albumArtImageView.isHidden = false
                }
            }
        }
    }

    /// Updates the album art image view size from UserDefaults preference.
    /// Only changes constraint constants — does not create new constraints.
    private func applyAlbumArtSize() {
        let sizeIndex = UserDefaults.standard.object(forKey: LirikPreferenceViewController.keyAlbumArtSize) as? Int ?? 1
        let sizes: [CGFloat] = [20, 24, 28]
        let size = sizes[max(0, min(sizeIndex, sizes.count - 1))]
        albumArtWidthConstraint?.constant = size
        albumArtHeightConstraint?.constant = size
    }

    /// No animation on Touch Bar — Pock's DFR rendering pipeline
    /// doesn't animate NSTextField smoothly. The 2-line karaoke mode
    /// provides natural visual continuity by previewing the next line.
    private func setLineText(_ label: NSTextField, _ text: String) {
        label.stringValue = text
    }

    /// Returns the track info as (title, artist) tuple or nil if track info display is not active.
    /// Karaoke style: song title on top (bold), artist name below (small/muted).
    /// Extracts featuring info from the title and appends it to the artist for display,
    /// since Spotify's AppleScript API only returns the primary artist.
    private func trackInfoComponents() -> (title: String, artist: String)? {
        guard let until = trackInfoVisibleUntil, Date() < until,
              let track = nowPlayingWatcher.currentTrack else { return nil }

        let displayArtist = artistWithFeaturing(artist: track.artist, title: track.title)
        return (title: track.title, artist: displayArtist)
    }

    /// Extracts featuring info (ft., feat., with) from the track title and appends
    /// it to the artist name for display purposes only. Does not affect lyrics search.
    ///
    /// Examples:
    ///   - title: "Song (feat. Artist B)", artist: "Artist A" → "Artist A ft. Artist B"
    ///   - title: "Song [ft. Artist B]", artist: "Artist A" → "Artist A ft. Artist B"
    ///   - title: "Song", artist: "Artist A" → "Artist A" (unchanged)
    private func artistWithFeaturing(artist: String, title: String) -> String {
        // Match patterns: (feat. ...), [feat. ...], (ft. ...), [ft. ...], (with ...)
        // Also matches unparenthesized: "Song feat. Artist B", "Song ft. Artist B"
        let patterns = [
            "\\(feat\\.\\s*([^)]+)\\)",
            "\\[feat\\.\\s*([^\\]]+)\\]",
            "\\(ft\\.\\s*([^)]+)\\)",
            "\\[ft\\.\\s*([^\\]]+)\\]",
            "\\(with\\s+([^)]+)\\)",
            "\\[with\\s+([^\\]]+)\\]",
            "\\sfeat\\.\\s+(.+)$",
            "\\sft\\.\\s+(.+)$"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: title, options: [], range: NSRange(title.startIndex..., in: title)),
               let featRange = Range(match.range(at: 1), in: title) {
                let featArtist = String(title[featRange]).trimmingCharacters(in: .whitespaces)
                if !featArtist.isEmpty {
                    return "\(artist) ft. \(featArtist)"
                }
            }
        }

        return artist
    }
}
