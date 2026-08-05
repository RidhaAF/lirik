# AGENTS.md

Operating instructions for any AI coding agent (Claude Code, Codex, Cursor, etc.) working in this repository. Read this before touching any code. Product context, scope, and rationale live in `PRD.md` — read that first if you haven't.

**Assumption baked into this file:** built as a **Pock plugin (PockKit)**, not a standalone DFRFoundation app (PRD §7.2, Option B). If this project pivots to Option A (standalone app), most sections below still apply — only §3 (Touch Bar presentation) and the dependency setup in §4 change. Flag it explicitly if you're working under Option A instead.

---

## 1. Project Summary

macOS Touch Bar widget showing real-time synced lyrics for whatever's playing in Spotify or Apple Music. Built as a Pock plugin. No backend, no user accounts, fully client-side. See `PRD.md` for full scope, non-goals, and success criteria.

## 2. Stack

- **Language:** Swift (match the Swift version PockKit's host app targets — check Pock's own `Package.swift`/Xcode project before assuming latest).
- **UI layer:** PockKit widget (`PKWidget` conformance), not raw `NSTouchBar`.
- **Now-playing detection:** `MediaRemote.framework` (private, no public header) via `dlopen`/`dlsym`.
- **Lyrics:** LRCLIB REST API (primary, synced LRC), Genius API (fallback, static text only).
- **Persistence:** local cache only — plist or a single SQLite file. No cloud sync, no backend.
- **No third-party dependency manager beyond Swift Package Manager.** Don't introduce CocoaPods/Carthage.

## 3. Touch Bar Presentation Rules

- All Touch Bar rendering goes through PockKit's widget lifecycle (`viewAppeared`, `viewDisappeared`, etc.) — don't bypass it with direct `DFRFoundation` calls. That's the whole point of building on Pock instead of from scratch.
- Widget must degrade gracefully if Pock itself isn't running / isn't installed correctly — never crash the host.
- Keep the widget's rendered width flexible; don't hardcode pixel widths assuming a specific Touch Bar model.

## 4. Setup & Build

- Requires Xcode (version TBD once PockKit's minimum is confirmed — check before scaffolding).
- Requires Pock installed locally for manual testing (widget won't render in isolation — it's hosted inside Pock's process).
- **Cannot be tested in the iOS/macOS Simulator** — Touch Bar hardware or Pock's dev harness only, if one exists. If Pock ships no simulator/preview mode, say so explicitly rather than assuming one.
- Build command / run command: fill in once the Xcode project is scaffolded — don't guess a `swift build` invocation that hasn't been verified against PockKit's actual project structure.

## 5. Code Style & Conventions

- Follow Apple's Swift API Design Guidelines (clear names over abbreviations, no Hungarian notation).
- **No force unwraps (`!`)** except with an inline comment explaining why it's provably safe at that point. Prefer `guard let` / `if let`.
- Use `async`/`await` for all network calls (LRCLIB, Genius) and file I/O — never block the main thread, especially inside the Touch Bar render path.
- Organize files by responsibility, not by type — one file per concern (see §8), not `Models.swift` / `Views.swift` dumping grounds.
- No placeholder/generic naming (`Manager`, `Helper`, `Utils` as a catch-all). Name things for what they specifically do: `NowPlayingWatcher`, `LRCSyncEngine`, `LyricsCache` — not `MusicManager`, `SyncHelper`.
- Comments explain *why*, not *what* — don't narrate obvious code.

## 6. Commit & PR Rules

- **Conventional commits**, small and atomic — one logical change per commit (matches existing project conventions).
  - Examples: `feat(now-playing): add MediaRemote bridging via dlsym`, `fix(sync): correct drift on seek events`, `chore(cache): switch plist to sqlite`.
- Don't bundle unrelated changes (e.g., a lyrics-matching fix + a UI tweak) into one commit.
- If a change deviates from what `PRD.md` specifies, note which PRD section it deviates from in the commit body or PR description — don't silently diverge from the spec.

## 7. Architecture Rules — Do / Don't

**Do:**
- Isolate all `MediaRemote` private-API access behind a single `NowPlayingWatcher` type. Nothing else in the codebase should `dlsym` directly.
- Cache every LRCLIB lookup to disk *before* attempting a second network call for the same track ID. Never refetch on every play of a previously-seen track.
- Treat `MediaRemote` elapsed-time updates as the single source of truth for sync position — don't run a separate local timer that can drift from actual playback.
- Handle "no lyrics found" and "lyrics found but not synced" as distinct, explicit states in the UI layer — not silently falling back to a blank widget.

**Don't:**
- Don't touch `DFRFoundation` or any raw private Touch Bar drawing — that's what Pock/PockKit exists to abstract away here.
- Don't store the Genius API key (or any credential) in source. Use a gitignored local config file or environment variable, and document the expected key name in `README.md` when that's created.
- Don't add Spotify/Apple Music OAuth flows — this project intentionally reads local playback state only (PRD §9), not cloud APIs.
- Don't add playback controls (play/pause/skip/seek-via-remote) — explicitly out of scope (PRD §3, §14).

## 8. Suggested File Structure

```
Sources/
  NowPlaying/
    NowPlayingWatcher.swift       # MediaRemote bridging, single source of truth
  Lyrics/
    LRCLIBClient.swift            # primary lyrics source
    GeniusClient.swift            # static-text fallback
    LRCParser.swift               # parses raw LRC into timestamped lines
    LyricsCache.swift             # disk cache, keyed by track ID
  Sync/
    LRCSyncEngine.swift           # matches elapsed time -> current line
  Widget/
    LyricsWidget.swift            # PockKit PKWidget conformance, rendering only
  App/
    (plugin manifest / entry point per PockKit's required structure)
```

Rendering code (`Widget/`) should contain no networking or parsing logic — it only reads state produced by `Sync/` and `Lyrics/`.

## 9. Testing

- **Unit-testable in isolation (write real tests for these):**
  - `LRCParser` — malformed/edge-case LRC input handling.
  - `LRCSyncEngine` — given a track's elapsed time, does it resolve the correct current line, including edge cases (before first line, after last line, exact-timestamp boundaries).
  - `LyricsCache` — read/write/eviction behavior.
- **Not unit-testable, manual QA only:**
  - `NowPlayingWatcher` (depends on live system state via private framework).
  - `LyricsWidget` rendering (depends on Pock host + physical Touch Bar).
  - Note this limitation rather than writing brittle mocks that don't reflect real private-API behavior.

## 10. Permissions

- Accessibility permission: only required if a fallback AppleScript polling path is added (PRD §7.1 fallback). Not required for the MediaRemote-only path.
- **Automation permission: required on macOS 15.4+** where MediaRemote.framework is blocked by entitlement enforcement and AppleScript polling is the primary backend. macOS will prompt the user on first use for each target app (Spotify, Apple Music). Not required on older macOS where MediaRemote still works.
- No network entitlement beyond standard outbound HTTPS to LRCLIB/Genius.

## 11. Known Fragile Areas & Verified Environment

- **MediaRemote.framework API Blocked on macOS 15.4+**: `MRMediaRemoteGetNowPlayingInfo` symbols resolve via `dlsym`, but callbacks silently fail due to entitlement enforcement in `mediaremoted`. Dual-backend architecture uses `AppleScriptBackend` on macOS 15.4+ and `MediaRemoteBackend` on older macOS.
- **Environment Verified Against**:
  - **macOS**: `macOS 15.7.7` (Build `24G720`, Apple Silicon `arm64`)
  - **Xcode**: `Xcode 26.3` (Build `17C529`)
  - **Swift**: `Apple Swift version 6.2.4` (Effective Swift 5 mode)
  - **PockKit**: `PockKit 0.3.0` via CocoaPods (`lirik.xcworkspace`)
- Track matching (artist + title + duration against LRCLIB) is heuristic, not exact. If you touch matching logic, check it against a few known edge cases (live versions, remixes, features) before considering it done.
- Pock's own PockKit API surface may change between Pock releases — pinned against PockKit 0.3.0.

## 12. Explicitly Out of Scope (don't build these without updating PRD.md first)

- Playback controls of any kind.
- Lyrics editing/correction UI.
- Translated or romanized lyrics.
- Any Mac App Store distribution path (private API usage makes this a non-starter — PRD §11).
- Non-Touch-Bar Mac support (menu bar fallback is PRD v1.1, not now).
