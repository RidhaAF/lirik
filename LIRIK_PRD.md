# PRD: Touch Bar 'Lirik' Widget

**Status:** Draft v1
**Owner:** Ridha
**Platform:** macOS, Touch Bar MacBook Pro (2016–2020 models only)
**Working names:** `Lirik`

---

## 1. Summary

A system-wide macOS utility that shows real-time, karaoke-style synced lyrics on the Touch Bar for whatever is currently playing in Spotify or Apple Music — no need to switch apps or look at your phone. Lives on the Touch Bar permanently (not just when the app is frontmost), auto-detects track changes, and scrolls the current line in sync with playback.

## 2. Problem & Motivation

Lyrics apps exist (Musixmatch, Apple Music's own lyrics view), but they all require you to tab away from what you're doing to see them. The Touch Bar is prime unused real estate on the Macs that have it — this puts lyrics exactly where your eyes already glance for volume/brightness controls, with zero context-switching cost.

Worth naming honestly: Touch Bar MacBook Pros were discontinued in late 2021, so the addressable "market" is shrinking (2016–2020 15"/13" MBP owners only). This is best framed as a **systems-level portfolio piece** — private framework integration, real-time sync engineering, low-level macOS work — rather than a growth product. That framing should inform how much polish/scope goes into things like settings UI vs. how much goes into the sync engine itself.

## 3. Goals

- Detect currently playing track from **either** Spotify or Apple Music automatically, no manual source switching.
- Fetch time-synced lyrics and scroll them on the Touch Bar in step with playback, karaoke-style.
- Persistent on the Touch Bar regardless of which app is frontmost.
- Manual refresh (for when auto-match picks the wrong lyrics or metadata lags).
- Clean quit.

### Non-Goals (v1)
- Editing/correcting lyrics in-app.
- Translated/romanized lyrics.
- Windows/other platforms.
- Playback controls (play/pause/skip) — this is a *lyrics display*, not a remote.
- Mac App Store distribution (see §11 — technically not viable for v1's architecture).

## 4. Users

Primarily Ridha, daily use while working/running training playlists. Secondary: anyone in the (admittedly shrinking) Touch Bar Mac + open source utility community — plausible GitHub/Homebrew release.

## 5. Core User Flow

1. User launches app once; it installs as a background menu bar agent (no dock icon).
2. User plays a song in Spotify or Apple Music, in any app or even the browser.
3. Touch Bar widget picks up the track within ~1 second, shows artist – title briefly, then transitions to synced lyrics.
4. Current line is highlighted/bold; upcoming line is dimmed and scrolls in as the song progresses.
5. If lyrics are wrong/missing, user taps a refresh icon to re-fetch.
6. User taps an exit/quit icon (or uses the menu bar item) to close the app entirely.

## 6. Feature Scope

**MVP (v1)**
- Unified "now playing" detection across Spotify + Apple Music (see §7.1).
- Synced lyrics fetch + local caching per track.
- Karaoke-style scroll on Touch Bar.
- Refresh button.
- Quit button.
- Graceful fallback: if no synced lyrics exist, show static lyrics (no scroll) or "no lyrics found."

**v1.1+ (nice-to-have, not blocking)**
- Tap a lyric line to seek playback to that point.
- Font size / scroll speed preference.
- Menu bar dropdown fallback for non-Touch-Bar Macs (extends usefulness, low effort since now-playing engine is shared).
- Offline cache warm-up for playlists.

**Explicitly out of scope for v1:** see §14.

## 7. Technical Architecture

### 7.1 Now-playing detection — the key architectural decision

Spotify and Apple Music each expose track info via AppleScript (`tell application "Spotify"/"Music" to get current track`), but building **two separate integrations** doubles the surface area and neither gives sub-second playback position reliably for both.

**Recommendation:** Use `MediaRemote.framework` — the private framework macOS itself uses to power Control Center's "Now Playing" widget. It exposes now-playing metadata (title, artist, album, artwork, elapsed time, duration) for *any* currently playing source system-wide — Spotify, Apple Music, Safari, Chrome, podcasts — through one API, via `dlopen`/`dlsym` since Apple ships no public header. This is the same mechanism used by existing open-source "Now Playing" menu bar utilities, so it's a well-trodden path.

This single decision satisfies "both from day one" for free, and even extends beyond just those two apps.

- *Fallback if MediaRemote proves unstable on a given OS version:* per-app AppleScript polling (~every 500ms) as a secondary source, used only for apps MediaRemote doesn't report cleanly.

### 7.2 Touch Bar presentation — two viable paths

Apple's *public* `NSTouchBar` API only renders your UI when your app is frontmost — that's a dealbreaker for "always visible." True system-wide presence (what Pock, TouchBarDock, and similar tools do) requires drawing directly to the physical Touch Bar via the private `DFRFoundation` framework, plus Accessibility permissions to detect app-switch events and coexist with (or replace) the system Control Strip.

**Option A — Standalone app, own DFRFoundation integration.**
Full ownership, strongest portfolio/systems-programming demonstration, but you're building the touch-bar-hijacking layer *and* the lyrics layer from scratch. Higher risk of breaking across macOS point releases since it's undocumented API.

**Option B — Build as a Pock plugin (PockKit).**
[Pock](https://github.com/pigigaldi/Pock) already solved system-wide Touch Bar presence and ships a plugin SDK (PockKit) specifically so third parties can add widgets to its always-on strip without reimplementing DFRFoundation integration, Control Strip coexistence, or the notarization/permissions dance. You'd write essentially just the now-playing + lyrics-sync + rendering logic.

**Recommendation: start with Option B.** Given your usual one-week-build pattern, it gets you to a working, daily-usable widget far faster, and the sync engine (the actually novel/hard part) is identical either way. If it becomes something you want as a flagship portfolio piece later, the sync engine ports directly into a standalone Option-A build.

### 7.3 Lyrics source & sync engine

Neither Spotify's nor Apple Music's public APIs expose synced lyrics (licensing). Options:

| Source | Synced (LRC)? | Auth needed | Notes |
|---|---|---|---|
| **LRCLIB** | Yes | No | Free, open, community-sourced, built for exactly this use case (used by Spicetify plugins etc.) — **primary source** |
| Musixmatch | Partial | Yes, limited free tier | Good coverage, but sync access is gated behind partnership tiers |
| Genius | No (plain text only) | API key | **Fallback** for static-only display when LRCLIB has no match |

Match tracks by artist + title (+ duration as a disambiguator) against LRCLIB, cache the LRC response locally keyed by track ID so repeat plays don't refetch. Sync engine ticks off `MediaRemote`'s elapsed-time value against LRC timestamps to drive the scroll — no need to build your own clock/drift-correction from scratch, just resync elapsed time on every MediaRemote update (they push on play/pause/seek, so drift stays low).

*Light legal note, not legal advice:* displaying lyrics for personal use is low-risk; if you ever open-source or distribute this, it's worth being aware lyrics are copyrighted and redistribution/caching at scale is the part that occasionally draws takedown attention (this is why Musixmatch gates its synced tier). Not a blocker for a personal daily-use tool.

### 7.4 Data flow

```
MediaRemote.framework (system) ──► Now-Playing Watcher
                                         │
                                (title, artist, elapsed time)
                                         │
                                         ▼
                              Track Change? ──yes──► LRCLIB lookup ──► cache
                                         │                                │
                                         no                               ▼
                                         │                        Parsed LRC lines
                                         ▼                                │
                              Elapsed time tick ─────────────────────────►│
                                                                           ▼
                                                            Touch Bar renderer
                                                         (current line highlighted,
                                                          next line scrolling in)
```

### 7.5 Suggested tech stack

- Swift, AppKit (PockKit plugins are Swift-based).
- `dlopen`/`dlsym` bridging header for MediaRemote symbols.
- Lightweight local cache: JSON or SQLite keyed by track ID — plist is fine too given low volume.
- No backend needed — everything is client-side against LRCLIB/Genius.

## 8. Touch Bar UI/UX Design Direction

The Touch Bar is a ~30px-tall strip, so this needs a distinct visual identity, not a generic "text on black background" look. A direction worth considering: lean into a **tape/vinyl-groove motif** — current line rendered bold and bright, with a thin horizontal progress indicator underneath styled like a stylus/tape-head position rather than a generic progress bar. Keeps it recognizable at a glance and ties into "music" without resorting to a stock waveform icon.

Refresh and quit icons should be minimal glyphs (not text labels) to leave maximum width for scrolling lyrics — Touch Bar real estate is scarce.

## 9. Permissions & System Requirements

- macOS with physical Touch Bar (2016–2020 MacBook Pro).
- Accessibility permission (for app-switch/Control Strip coexistence, if going Option A).
- Automation permission for Spotify/Music (only needed if falling back to AppleScript).
- No Spotify/Apple Music account OAuth required — MediaRemote reads local playback state, not cloud state.

## 10. Risks & Open Questions

- **Private API fragility:** MediaRemote and DFRFoundation are undocumented and can shift between macOS versions. Budget for occasional maintenance after OS updates — this is the main ongoing cost of this architecture.
- **Lyrics match accuracy:** artist/title string matching against LRCLIB won't be perfect (remixes, live versions, features). Refresh button is the manual escape hatch; consider fuzzy matching later.
- **Shrinking device base:** worth deciding up front whether this is "just for me" or "for the Touch Bar community" — affects how much you invest in onboarding/settings polish.
- **Open question for you:** Option A vs B (§7.2) — want to lock that in before scaffolding?

## 11. Distribution Plan

Because this depends on private frameworks, **Mac App Store distribution isn't viable** — Apple's review rejects private API usage. Path: notarized direct download (DMG) + optional Homebrew cask, same pattern as Pock/Stats/other Touch Bar utilities. If built as a Pock plugin (Option B), distribution is even simpler — published through Pock's plugin listing.

## 12. Success Metrics

Since this is a personal/portfolio tool rather than a growth product:
- You actually use it daily without turning it off.
- Lyrics sync drift stays under ~300ms perceptible lag.
- Lyrics match hit-rate on your own regular playlists (rough manual spot-check, not formal analytics).

## 13. Suggested Build Plan

1. **Day 1:** MediaRemote now-playing watcher, print track changes to console — validate detection across Spotify + Apple Music + browser.
2. **Day 2:** LRCLIB integration, LRC parsing, local cache.
3. **Day 3:** Sync engine — tick elapsed time against parsed lines, verify drift is acceptable.
4. **Day 4–5:** Touch Bar rendering (PockKit widget if Option B), scroll animation, refresh/quit controls.
5. **Day 6:** Design pass (§8), edge cases (no lyrics found, track paused, rapid track skipping).
6. **Day 7:** Notarize, package, daily-drive it for bugs.

## 14. Out of Scope / Future Ideas

- Playback controls.
- Translated lyrics.
- Cross-device sync of lyric corrections.
- Non-Touch-Bar Mac support (menu bar fallback is a v1.1 idea, not v1).
- Windows/Linux.
