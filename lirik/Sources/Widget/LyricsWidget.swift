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
enum LyricsWidgetUIState {
    case noTrackPlaying
    case loading(title: String, artist: String)
    case noLyricsFound(title: String, artist: String)
    case staticOnly(title: String, artist: String, text: String)
    case synced(title: String, artist: String, lines: [LRCLine])
}

final class LyricsWidget: NSObject, PKWidget {

    // MARK: - PKWidget Protocol Properties

    static var identifier: String = "io.github.ridhaaf.lirik"
    var customizationLabel: String = "Lirik - Synced Lyrics"
    var view: NSView!

    // MARK: - UI Components

    private let containerView = NSStackView()
    private let textStackView = NSStackView()
    private let currentLineLabel = NSTextField(labelWithString: "Lirik")
    private let nextLineLabel = NSTextField(labelWithString: "")
    private let refreshButton = PKButton(title: "↺", target: nil, action: nil)
    private let closeButton = PKButton(title: "✕", target: nil, action: nil)

    // MARK: - Logic Dependencies

    private let nowPlayingWatcher = NowPlayingWatcher()
    private let lrclibClient = LRCLIBClient()
    private let lyricsCache = LyricsCache()

    // MARK: - Widget State

    private var uiState: LyricsWidgetUIState = .noTrackPlaying {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.updateUI()
            }
        }
    }

    private var activeLines: [LRCLine] = []

    // MARK: - Init

    required override init() {
        super.init()
        setupUI()
        setupWatcherCallbacks()
    }

    // MARK: - PKWidget Lifecycle Hooks

    func viewAppeared() {
        NSLog("[LyricsWidget] viewAppeared — starting NowPlayingWatcher")
        nowPlayingWatcher.startWatching()
    }

    func viewDisappeared() {
        NSLog("[LyricsWidget] viewDisappeared — stopping NowPlayingWatcher")
        nowPlayingWatcher.stopWatching()
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Container stack view (horizontal: text display + action buttons)
        containerView.orientation = .horizontal
        containerView.alignment = .centerY
        containerView.distribution = .fill
        containerView.spacing = 8
        containerView.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        // Text stack view (vertical: current line + next line)
        textStackView.orientation = .vertical
        textStackView.alignment = .leading
        textStackView.distribution = .fillProportionally
        textStackView.spacing = 1

        // Current line label (bold / highlighted)
        currentLineLabel.font = NSFont.boldSystemFont(ofSize: 13)
        currentLineLabel.textColor = .labelColor
        currentLineLabel.lineBreakMode = .byTruncatingTail
        currentLineLabel.stringValue = "Lirik"

        // Next line label (dimmed / secondary)
        nextLineLabel.font = NSFont.systemFont(ofSize: 11)
        nextLineLabel.textColor = .secondaryLabelColor
        nextLineLabel.lineBreakMode = .byTruncatingTail
        nextLineLabel.stringValue = ""

        textStackView.addArrangedSubview(currentLineLabel)
        textStackView.addArrangedSubview(nextLineLabel)

        // Configure Refresh Button
        refreshButton.target = self
        refreshButton.action = #selector(handleRefresh)
        refreshButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        // Configure Close Button (Hides widget view per user preference)
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        containerView.addArrangedSubview(textStackView)
        containerView.addArrangedSubview(refreshButton)
        containerView.addArrangedSubview(closeButton)

        self.view = containerView
    }

    // MARK: - Watcher Callbacks

    private func setupWatcherCallbacks() {
        // Handle track changes
        nowPlayingWatcher.onTrackChange = { [weak self] track in
            guard let self else { return }
            if let track = track {
                self.loadLyrics(for: track, forceRefresh: false)
            } else {
                self.activeLines = []
                self.uiState = .noTrackPlaying
            }
        }

        // Handle elapsed time ticks for synced lyrics
        nowPlayingWatcher.onElapsedTimeUpdate = { [weak self] elapsed in
            guard let self else { return }
            guard case .synced(_, _, let lines) = self.uiState else { return }

            let snapshot = LRCSyncEngine.resolve(elapsedTime: elapsed, lines: lines)
            DispatchQueue.main.async {
                self.renderSyncSnapshot(snapshot)
            }
        }
    }

    // MARK: - Lyrics Loading & Caching Flow

    private func loadLyrics(for track: NowPlayingTrack, forceRefresh: Bool) {
        uiState = .loading(title: track.title, artist: track.artist)

        // Step 1: Check cache unless forceRefresh is true
        if !forceRefresh,
           let cached = lyricsCache.get(title: track.title, artist: track.artist, duration: track.duration) {
            applyCachedLyrics(cached, for: track)
            return
        }

        // Step 2: Query LRCLIB REST API asynchronously
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.lrclibClient.fetchLyrics(
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration
                )

                let cachedEntry: CachedLyrics
                let newState: LyricsWidgetUIState

                switch result {
                case .synced(let id, let lrcText, _):
                    let parsedLines = LRCParser.parse(lrcText)
                    cachedEntry = CachedLyrics(
                        lrclibID: id,
                        trackKey: LyricsCache.makeTrackKey(title: track.title, artist: track.artist, duration: track.duration),
                        lyricsState: .synced(lines: parsedLines, rawLRC: lrcText),
                        cachedAt: Date()
                    )
                    newState = .synced(title: track.title, artist: track.artist, lines: parsedLines)
                    self.activeLines = parsedLines

                case .plainOnly(let id, let plainText):
                    cachedEntry = CachedLyrics(
                        lrclibID: id,
                        trackKey: LyricsCache.makeTrackKey(title: track.title, artist: track.artist, duration: track.duration),
                        lyricsState: .plainOnly(text: plainText),
                        cachedAt: Date()
                    )
                    newState = .staticOnly(title: track.title, artist: track.artist, text: plainText)
                    self.activeLines = []

                case .notFound:
                    cachedEntry = CachedLyrics(
                        lrclibID: nil,
                        trackKey: LyricsCache.makeTrackKey(title: track.title, artist: track.artist, duration: track.duration),
                        lyricsState: .notFound,
                        cachedAt: Date()
                    )
                    newState = .noLyricsFound(title: track.title, artist: track.artist)
                    self.activeLines = []
                }

                self.lyricsCache.save(cachedEntry)
                self.uiState = newState

            } catch {
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

        case .loading(let title, let artist):
            currentLineLabel.stringValue = "\(title) — \(artist)"
            currentLineLabel.textColor = .labelColor
            nextLineLabel.stringValue = "Fetching lyrics..."

        case .noLyricsFound(let title, let artist):
            currentLineLabel.stringValue = "\(title) — \(artist)"
            currentLineLabel.textColor = .labelColor
            nextLineLabel.stringValue = "No synced lyrics available"

        case .staticOnly(let title, let artist, _):
            currentLineLabel.stringValue = "\(title) — \(artist)"
            currentLineLabel.textColor = .labelColor
            nextLineLabel.stringValue = "Static lyrics (not time-synced)"

        case .synced(let title, let artist, let lines):
            if lines.isEmpty {
                currentLineLabel.stringValue = "\(title) — \(artist)"
                nextLineLabel.stringValue = "No lyrics text"
            } else {
                currentLineLabel.stringValue = "\(title) — \(artist)"
                nextLineLabel.stringValue = "Lyrics synced (\(lines.count) lines)"
            }
        }
    }

    private func renderSyncSnapshot(_ snapshot: LRCSyncSnapshot) {
        switch snapshot.positionState {
        case .empty:
            break

        case .beforeFirstLine:
            if let upcoming = snapshot.upcomingLine {
                currentLineLabel.stringValue = "♪ Intro"
                currentLineLabel.textColor = .secondaryLabelColor
                nextLineLabel.stringValue = upcoming.text
            }

        case .inLyrics:
            currentLineLabel.textColor = .labelColor
            currentLineLabel.stringValue = snapshot.currentLine?.text.isEmpty == true
                ? "♪ (instrumental)"
                : snapshot.currentLine?.text ?? ""

            nextLineLabel.stringValue = snapshot.upcomingLine?.text ?? ""

        case .afterLastLine:
            currentLineLabel.textColor = .labelColor
            currentLineLabel.stringValue = snapshot.currentLine?.text ?? ""
            nextLineLabel.stringValue = "♪ Outro"
        }
    }

    // MARK: - Button Actions

    @objc private func handleRefresh() {
        NSLog("[LyricsWidget] Refresh tapped — forcing LRCLIB re-fetch")
        guard let track = nowPlayingWatcher.currentTrack else { return }
        loadLyrics(for: track, forceRefresh: true)
    }

    @objc private func handleClose() {
        NSLog("[LyricsWidget] Close tapped — hiding widget view from Touch Bar")
        view.isHidden = true
    }
}
