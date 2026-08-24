//
//  MediaRemoteBackend.swift
//  lirik
//
//  Isolates all MediaRemote.framework private-API access behind a
//  single type, per AGENTS.md §7. Nothing else in the codebase
//  should call dlsym or CFBundleGetFunctionPointerForName directly.
//
//  ⚠️  KNOWN BROKEN on macOS 15.4+ (Sequoia 15.4, build 24E5xxx+).
//  Apple's mediaremoted daemon now enforces entitlements that third-party
//  apps lack. The symbols still resolve via dlsym, but callbacks silently
//  never fire. On macOS 15.7.7 (build 24G720), both
//  MRMediaRemoteGetNowPlayingInfo and
//  MRMediaRemoteRegisterForNowPlayingNotifications return nothing.
//
//  Last verified working: macOS 14.x (Sonoma) and earlier.
//  Last verified broken:  macOS 15.7.7 (build 24G720), 2026-08-05.
//

import Foundation

/// Backend that uses the private MediaRemote.framework to read
/// system-wide now-playing info. Falls back gracefully if the
/// framework cannot be loaded or the API is blocked by entitlements.
final class MediaRemoteBackend {

    // MARK: - Types

    /// Callback signature for MRMediaRemoteGetNowPlayingInfo.
    /// The dictionary uses CFString keys like "kMRMediaRemoteNowPlayingInfoTitle".
    private typealias GetNowPlayingInfoFn =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void

    /// Callback signature for MRMediaRemoteRegisterForNowPlayingNotifications.
    private typealias RegisterForNotificationsFn =
        @convention(c) (DispatchQueue) -> Void

    // MARK: - Known MediaRemote info-dictionary keys
    // These are CFString constants exported by MediaRemote.framework.
    // Discovered via nm / open-source projects; undocumented by Apple.

    static let titleKey      = "kMRMediaRemoteNowPlayingInfoTitle"
    static let artistKey     = "kMRMediaRemoteNowPlayingInfoArtist"
    static let albumKey      = "kMRMediaRemoteNowPlayingInfoAlbum"
    static let durationKey   = "kMRMediaRemoteNowPlayingInfoDuration"
    static let elapsedKey    = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    static let playbackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    /// Wall-clock timestamp (Date) when MediaRemote captured the elapsed-time snapshot.
    /// Used to interpolate live elapsed = snapshot + (now - timestamp) * playbackRate.
    /// Without this, elapsed values go stale between MediaRemote pushes (which do NOT
    /// tick continuously — see refetchTimer comment). Especially critical after Touch Bar
    /// sleep or system sleep, when refetches may have been paused.
    static let infoUpdateTimeKey = "kMRMediaRemoteNowPlayingInfoTimestamp"

    // Notification names posted by MediaRemote via NotificationCenter.
    static let infoDidChangeNotification =
        NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let appDidChangeNotification =
        NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
    static let playbackStateDidChangeNotification =
        NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")

    // MARK: - State

    private var getNowPlayingInfo: GetNowPlayingInfoFn?
    private var registerForNotifications: RegisterForNotificationsFn?
    private var notificationObservers: [NSObjectProtocol] = []
    private var onUpdate: (([String: Any]) -> Void)?

    /// Periodic refetch timer. MediaRemote notifications only fire on
    /// state transitions (play/pause, track change, metadata change) —
    /// they do NOT tick continuously with elapsed time. Without a local
    /// timer, lyrics freeze after resume because the widget only ever
    /// receives one elapsed-time snapshot per state change.
    ///
    /// The 1s interval matches AppleScriptBackend's polling cadence and
    /// keeps lyric-line resolution current while playing.
    private var refetchTimer: Timer?
    private let refetchInterval: TimeInterval = 1.0

    /// Whether the framework loaded and symbols resolved successfully.
    private(set) var isAvailable: Bool = false

    // MARK: - Init

    init() {
        loadFramework()
    }

    // MARK: - Framework loading

    /// Loads MediaRemote.framework and resolves function pointers via
    /// CFBundleGetFunctionPointerForName. All dlsym-equivalent access
    /// is confined to this method — per AGENTS.md §7 and §11.
    private func loadFramework() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework"

        guard let bundleURL = NSURL(fileURLWithPath: frameworkPath) as CFURL?,
              let bundle = CFBundleCreate(kCFAllocatorDefault, bundleURL) else {
            NSLog("[MediaRemoteBackend] Could not load MediaRemote.framework at \(frameworkPath)")
            return
        }

        guard let getInfoPtr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString
        ) else {
            NSLog("[MediaRemoteBackend] MRMediaRemoteGetNowPlayingInfo symbol not found")
            return
        }

        guard let registerPtr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString
        ) else {
            NSLog("[MediaRemoteBackend] MRMediaRemoteRegisterForNowPlayingNotifications symbol not found")
            return
        }

        getNowPlayingInfo = unsafeBitCast(getInfoPtr, to: GetNowPlayingInfoFn.self)
        registerForNotifications = unsafeBitCast(registerPtr, to: RegisterForNotificationsFn.self)
        isAvailable = true

        NSLog("[MediaRemoteBackend] Framework loaded, symbols resolved")
    }

    // MARK: - Public API

    /// Attempts a one-shot fetch of now-playing info. Calls `completion`
    /// with the parsed track, or nil if the API is blocked/unavailable.
    /// The `timeout` parameter controls how long to wait for the callback
    /// before assuming the API is blocked (macOS 15.4+ entitlement issue).
    func fetchNowPlaying(
        timeout: TimeInterval = 2.0,
        completion: @escaping (NowPlayingTrack?) -> Void
    ) {
        guard let getNowPlayingInfo else {
            completion(nil)
            return
        }

        var didComplete = false
        let lock = NSLock()

        getNowPlayingInfo(DispatchQueue.main) { [weak self] info in
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()

            if info.isEmpty {
                completion(nil)
            } else {
                completion(self?.parseInfo(info))
            }
        }

        // Timeout guard — if the callback never fires (macOS 15.4+),
        // we report nil so the caller can fall back to another backend.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()

            NSLog("[MediaRemoteBackend] fetchNowPlaying timed out after \(timeout)s — API likely blocked by entitlements")
            completion(nil)
        }
    }

    /// Starts listening for now-playing change notifications.
    /// Calls `onUpdate` with the raw info dictionary on each change.
    func startObserving(onUpdate: @escaping ([String: Any]) -> Void) {
        guard let registerForNotifications else { return }

        self.onUpdate = onUpdate

        let notificationNames: [NSNotification.Name] = [
            Self.infoDidChangeNotification,
            Self.appDidChangeNotification,
            Self.playbackStateDidChangeNotification,
        ]

        for name in notificationNames {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refetchAndNotify()
            }
            notificationObservers.append(observer)
        }

        registerForNotifications(DispatchQueue.main)
        NSLog("[MediaRemoteBackend] Registered for now-playing notifications")

        // Start periodic refetch so elapsed time advances between state-change
        // notifications. Without this, `onUpdate` only fires on play/pause/track
        // events and lyrics freeze after resume (see refetchTimer doc above).
        // Scheduled on the main runloop in .common modes so Touch Bar / DFR
        // event tracking cannot pause the timer.
        let timer = Timer(timeInterval: refetchInterval, repeats: true) { [weak self] _ in
            self?.refetchAndNotify()
        }
        RunLoop.main.add(timer, forMode: .common)
        refetchTimer = timer
    }

    /// Stops listening and cleans up observers.
    func stopObserving() {
        refetchTimer?.invalidate()
        refetchTimer = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        onUpdate = nil
    }

    // MARK: - Internal

    private func refetchAndNotify() {
        guard let getNowPlayingInfo else { return }

        getNowPlayingInfo(DispatchQueue.main) { [weak self] info in
            self?.onUpdate?(info)
        }
    }

    /// Converts the raw MediaRemote info dictionary into a NowPlayingTrack.
    func parseInfo(_ info: [String: Any]) -> NowPlayingTrack? {
        guard let title = info[Self.titleKey] as? String, !title.isEmpty else {
            return nil
        }

        let artist = info[Self.artistKey] as? String ?? "Unknown Artist"
        let album = info[Self.albumKey] as? String
        let duration = info[Self.durationKey] as? TimeInterval
        let rawElapsed = info[Self.elapsedKey] as? TimeInterval
        let playbackRate = info[Self.playbackRateKey] as? Double ?? 0.0

        // Interpolate elapsed against wall-clock timestamp of the snapshot.
        // MediaRemote's elapsed field is a SNAPSHOT captured at `infoUpdateTime`,
        // not a live value. Between refetches (and especially after Touch Bar/system
        // sleep), the snapshot can be seconds stale — causing lyrics to freeze on the
        // "line at snapshot time" rather than the actual current playback line.
        let elapsed: TimeInterval?
        if let base = rawElapsed {
            if let snapshotDate = info[Self.infoUpdateTimeKey] as? Date, playbackRate > 0 {
                let delta = Date().timeIntervalSince(snapshotDate)
                // Clamp delta to non-negative; ignore clock skew going backwards.
                let live = base + max(0, delta) * playbackRate
                // Clamp against duration to avoid running past the end while stale.
                if let d = duration, d > 0 {
                    elapsed = min(live, d)
                } else {
                    elapsed = live
                }
            } else {
                elapsed = base
            }
        } else {
            elapsed = nil
        }

        return NowPlayingTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsed,
            isPlaying: playbackRate > 0,
            source: .unknown // MediaRemote doesn't reliably expose which app is playing
        )
    }
}
