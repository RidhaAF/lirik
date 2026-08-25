# Changelog

All notable changes to Lirik are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.3.1] — 2026-08-25

### Fixed
- **Lyrics no longer freeze** after Touch Bar sleep, system sleep, Spotify ad breaks, or pause/resume (#3, [@yasiramri](https://github.com/yasiramri)):
  - `MediaRemoteBackend` now interpolates live elapsed time from the snapshot timestamp (`elapsed = snapshot + (now − timestamp) × playbackRate`), clamped to track duration
  - Periodic 1s refetch keeps elapsed time advancing between MediaRemote state-change notifications
  - Poll/refetch timers run in the runloop's `.common` modes so Touch Bar (DFR) event tracking can no longer silently pause them
  - Widget force-refreshes on system wake, screen wake, session activation, and app activation

### Added
- Support for macOS 11.0 (Big Sur) through macOS 15.x — deployment target lowered from 15.7 to 11.0 (#3, [@yasiramri](https://github.com/yasiramri))

## [1.3.0] — 2026-08-07

### Added
- Realtime album artwork thumbnail with configurable size (#1, [@rizkifdh](https://github.com/rizkifdh))
- Brief karaoke-style track info display (title + artist) on track change
- "Show track info" preference toggle (#1, [@rizkifdh](https://github.com/rizkifdh))

### Fixed
- Automation permission dialog now appears even when Pock is launched from Spotlight (#1, [@rizkifdh](https://github.com/rizkifdh))
- Song title & artist display improvements (#1, [@rizkifdh](https://github.com/rizkifdh))

## [1.2.0] — 2026-08-05

### Added
- Smart title cleaning (strips "(Official Video)"-style noise)
- Text alignment options (left / center)
- "Clear lyrics cache" button in preferences
- Marquee scrolling for long lyric lines
- Expanded highlight color palette: White, Gold, Cyan, Green, Purple, Pink, Orange, Red

### Fixed
- Version string formatting in Pock Widgets Manager

## [1.1.0] — 2026-08-05

### Added
- Widget preferences panel (`LirikPreferenceViewController`) with highlight color selector
- Tap-to-copy gesture on the Touch Bar
- Auto-advance display for unsynced (static) lyrics
- Custom palette icon

### Fixed
- Touch Bar tap events now use native `PKButton`

## [1.0.0] — 2026-08-05

### Added
- Initial release: real-time synced lyrics on the Touch Bar via Pock
- LRCLIB synced lyrics (primary) + Genius static lyrics fallback
- Now-playing detection via MediaRemote.framework with AppleScript polling fallback
- Local lyrics cache

### Fixed
- Decimal-comma parsing in non-US system locales
- AppleScript backend switched to `/usr/bin/osascript` subprocess to bypass in-process TCC restrictions

[1.3.1]: https://github.com/RidhaAF/lirik/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/RidhaAF/lirik/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/RidhaAF/lirik/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/RidhaAF/lirik/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/RidhaAF/lirik/releases/tag/v1.0.0
