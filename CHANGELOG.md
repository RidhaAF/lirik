# Changelog

All notable changes to Lirik are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased] — 1.4.2

### Added
- Browser support expanded beyond Safari/Chrome/Edge to **Brave**, **Vivaldi**, **Opera**, **Chromium**, and **Arc**. Chromium forks reuse Chrome's scripting dictionary, so they get the same live `<video>` position and synced lyrics
- **Firefox**, **Zen**, and **LibreWolf** support: the playing YouTube tab is read from the accessibility tree (tab title only — Firefox ships no AppleScript tab interface, Mozilla bugs 369901 / 939528). Requires Accessibility permission; no position, video ID, captions, or thumbnail
- Estimated playback position for browsers that can't report one (Firefox, Arc, *Allow JavaScript from Apple Events* off), so static lyrics advance instead of freezing on the first line

### Fixed
- YouTube Music tracks now get MV-timeline calibration and video thumbnails. Both were gated on `source == .browser`, so every `music.youtube.com` track silently skipped them
- Chromium builds that refuse to script background tabs (-1723) are detected once per session and degrade to title-only instead of failing every poll
- A browser with *Allow JavaScript from Apple Events* disabled now logs the fix once instead of silently falling back

## [Unreleased] — 1.4.1

### Added
- YouTube Music support: `music.youtube.com` tabs resolve exact title/artist/album via Media Session metadata (tab titles stay generic) and report as their own source
- Audible-tab ranking: a muted/autoplaying background tab no longer shadows the video being watched (muted state read from the `<video>` element; replaces the AppleScript `audible` probe, which browsers don't expose)
- Lyrics timing offset preference, to nudge sync earlier or later when a track's timestamps drift (#5, [@vadhh](https://github.com/vadhh))

### Changed
- AppleScript polling reuses precompiled scripts instead of rebuilding them on every poll (#5, [@vadhh](https://github.com/vadhh))

### Fixed
- **Long lyric lines no longer blank the widget** (#4, [@vadhh](https://github.com/vadhh)):
  - Widget width is capped, so an over-long line makes the Touch Bar truncate it instead of dropping the whole item
  - Line font steps down (floor 8pt current, 7pt next) until the text fits, then truncates
  - The cap is a heuristic sized for one companion widget beside the Control Strip; a layout with less room still hides the item

## [Unreleased] — 1.4.0

### Added
- YouTube browser lyrics: picks up YouTube music videos playing in Safari, Chrome, or Edge via AppleScript tab polling, with live `<video>` position for synced karaoke lyrics (falls back to auto-advancing static lyrics when the browser's "Allow JavaScript from Apple Events" toggle is off)
- "Browser Only" Music Player Source option; priority is Spotify > Apple Music > Browser when several play at once
- LRCLIB swapped artist/title retry for "Title – Artist" ordered uploads, plus YouTube title-noise stripping (Official Music Video/Audio, Lyric Video, Visualizer, M/V, 4K/HD tags)
- Closed-caption fallback: when LRCLIB has no match for a YouTube video, lyrics come from the video's own captions (English-first), briefly cycling CC to capture them
- MV-timeline auto-calibration: album-timed lines shift to match dialogue-intro music videos using captions as ground truth
- Manual per-video timing offset stepper in preferences for videos that can't auto-calibrate
- YouTube video thumbnails as Touch Bar artwork (square-cropped 1:1, best quality available)

### Fixed
- Music Player Source preference is now actually honored when polling (previously write-only)
- Same song on different sources counts as a track change (durations and cache keys differ per source)
- TCC permission dialog now appears for browsers via a subprocess trigger (in-process AppleScript can't present it when Pock wasn't launched from Finder)

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
