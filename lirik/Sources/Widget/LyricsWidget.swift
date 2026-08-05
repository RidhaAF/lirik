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

    // MARK: - UI Components

    private let containerView = NSStackView()
    private let contentStackView = NSStackView()
    private let textStackView = NSStackView()

    private let currentLineLabel = NSTextField(labelWithString: "Lirik")
    private let nextLineLabel = NSTextField(labelWithString: "")

    // MARK: - Logic Dependencies

    private let nowPlayingWatcher = NowPlayingWatcher()
    private let lrclibClient = LRCLIBClient()
    private let lyricsCache = LyricsCache()

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
        // Ensure watcher starts watching immediately upon initialization
        nowPlayingWatcher.startWatching()
    }

    // MARK: - PKWidget Lifecycle Hooks

    func viewAppeared() {
        NSLog("[LyricsWidget] viewAppeared — starting NowPlayingWatcher")
        nowPlayingWatcher.startWatching()
    }

    func viewDisappeared() {
        NSLog("[LyricsWidget] viewDisappeared — stopping NowPlayingWatcher")
        inFlightFetchTask?.cancel()
        nowPlayingWatcher.stopWatching()
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Container stack view (horizontal: pure content)
        containerView.orientation = .horizontal
        containerView.alignment = .centerY
        containerView.distribution = .fill
        containerView.spacing = 0
        containerView.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

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

        // Next line label (dimmed 9pt for Touch Bar karaoke secondary line)
        nextLineLabel.font = NSFont.systemFont(ofSize: 9)
        nextLineLabel.textColor = .secondaryLabelColor
        nextLineLabel.lineBreakMode = .byTruncatingTail
        nextLineLabel.stringValue = ""

        textStackView.addArrangedSubview(currentLineLabel)
        textStackView.addArrangedSubview(nextLineLabel)

        contentStackView.addArrangedSubview(textStackView)

        containerView.addArrangedSubview(contentStackView)

        self.view = containerView
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
                self.loadLyrics(for: track, expectedKey: newKey, forceRefresh: false)
            } else {
                self.activeTrackKey = ""
                self.activeLines = []
                self.isCurrentlyPaused = false
                self.uiState = .noTrackPlaying
            }
        }

        // Handle elapsed time ticks for synced lyrics
        nowPlayingWatcher.onElapsedTimeUpdate = { [weak self] elapsed in
            guard let self else { return }

            guard let track = self.nowPlayingWatcher.currentTrack else { return }

            DispatchQueue.main.async {
                self.isCurrentlyPaused = !track.isPlaying

                // If track is paused, freeze line scroll animations
                if case .synced(_, _, let lines) = self.uiState {
                    let snapshot = LRCSyncEngine.resolve(elapsedTime: elapsed, lines: lines)
                    self.renderSyncSnapshot(snapshot, isPaused: !track.isPlaying)
                }
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

        case .permissionDenied(let appName):
            currentLineLabel.stringValue = "Permission Required"
            currentLineLabel.textColor = .systemRed
            nextLineLabel.stringValue = "Allow Pock -> \(appName) in System Settings"

        case .loading:
            currentLineLabel.stringValue = "Fetching lyrics..."
            currentLineLabel.textColor = .labelColor
            nextLineLabel.stringValue = ""

        case .noLyricsFound:
            currentLineLabel.stringValue = "No synced lyrics available"
            currentLineLabel.textColor = .secondaryLabelColor
            nextLineLabel.stringValue = ""

        case .staticOnly(_, _, let text):
            currentLineLabel.stringValue = "Static lyrics"
            currentLineLabel.textColor = .secondaryLabelColor
            let firstLine = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text
            nextLineLabel.stringValue = firstLine

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

    private func renderSyncSnapshot(_ snapshot: LRCSyncSnapshot, isPaused: Bool) {
        let prefix = isPaused ? "⏸ " : ""

        switch snapshot.positionState {
        case .empty:
            break

        case .beforeFirstLine:
            currentLineLabel.textColor = isPaused ? .secondaryLabelColor : .labelColor
            currentLineLabel.stringValue = "\(prefix)\(snapshot.upcomingLine?.text ?? "")"
            nextLineLabel.stringValue = activeLines.count > 1 ? activeLines[1].text : ""

        case .inLyrics:
            currentLineLabel.textColor = isPaused ? .secondaryLabelColor : .labelColor
            let text = snapshot.currentLine?.text.isEmpty == true
                ? "♪ (instrumental)"
                : snapshot.currentLine?.text ?? ""
            currentLineLabel.stringValue = "\(prefix)\(text)"
            nextLineLabel.stringValue = snapshot.upcomingLine?.text ?? ""

        case .afterLastLine:
            currentLineLabel.textColor = isPaused ? .secondaryLabelColor : .labelColor
            currentLineLabel.stringValue = "\(prefix)\(snapshot.currentLine?.text ?? "")"
            nextLineLabel.stringValue = ""
        }
    }
}
