# Changelog

All notable changes to Forel are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Added metadata conditions for matching files by download website and download app, backed by macOS where-from metadata.

## [0.1.0-beta.3] - 2026-06-18

### Added
- Dry Run now shows detailed per-file rule previews, including matched
  conditions, planned actions, source/target paths, and statuses such as
  "would run", "would skip", and "blocked by conflict".
- Dry Run now detects destination conflicts for move, copy, rename, trash,
  and delete previews without modifying files.
- Action history now records skipped and failed actions, including the reason
  or error message when available.
- Run Now shows a loading state while it's working and a confirmation
  message with the result once it's done.

### Changed
- New installs now start at login by default, and start with watching
  paused until you've set up your folders and rules.
- The old Preview action is now presented as Dry Run in the UI.
- The Dry Run window is larger to make rule details easier to inspect.
- The menu bar panel has more top padding so its header is not cramped under
  the popover arrow.
- The History view now groups activity by batch and file, shows full
  original path -> result path flow, and displays explicit status badges.
- Size conditions now default to MB instead of bytes.
- Crisper, better-sized menu bar icon.

### Fixed
- Fixed the "Update available" banner text getting cut off in the menu bar
  panel.
- Dry Run now follows simulated rename paths when evaluating following rules,
  matching the real execution order more closely.
- Condition rows in the rule editor now align consistently to the left.

## [0.1.0-beta.2] - 2026-06-17

### Fixed
- Fixed rules getting stuck when chained after a rename.
- Fixed the update checker sometimes offering an older alpha release
- Hardened folder-watching against a rare internal timing issue (no
  user-visible change).
- Rules with an invalid regex condition now show an error right in the
  editor and can't be saved, instead of silently never matching any file.
- Fixed the update checker occasionally announcing an update that wasn't
  actually downloadable yet, right after a new version was tagged.

## [0.1.0-beta.1] - 2026-06-17

The app has been rewritten from scratch in Swift, replacing the previous
Tauri + React + Rust stack (archived under `tauri/`). This isn't a port for
its own sake: a native SwiftUI/AppKit app gives Forel direct, low-level
control over the things that matter most for a file-automation tool —
FSEvents watching, the menu bar, window/login-item behavior, native macOS
look and feel — without a JS runtime or webview in the loop. It's a better
foundation for where the project is going: a simple, fast, and efficient
macOS-native experience, aimed at being a credible alternative to Hazel.

### Added
- Full native rewrite: SwiftUI/AppKit app shell (`ForelApp`) over a Swift
  core package (`ForelCore`) with its own rule engine, SQLite persistence,
  and FSEvents-based folder watcher.
- Menu bar quick panel: watching toggle, per-folder enable switches, and an
  activity summary, without opening the main window.
- Settings: appearance (theme, accent color), start at login, and update
  preferences, backed by the same SQLite `app_settings` table as the rest
  of the app's state.
- Self-updater: checks GitHub Releases for newer tags (every 12h, plus a
  manual "Check Now"), shows a prominent in-app banner and a menu bar badge
  when an update is available, and installs it in place — no Sparkle
  dependency, no appcast required.
- Action history with undo/redo per entry and per batch.

### Changed
- Continues the existing `0.1.0.x` line started by the Tauri-era alphas
  below — this beta is the same product, rebuilt on a native stack, not a
  fresh project.

### Removed
- The Tauri/React frontend and Rust backend are no longer the active app;
  the source is kept under `tauri/` for reference only.
- Sparkle dependency (was already disabled in dev builds; replaced by the
  GitHub Releases-based updater above).

## [0.1.0-alpha.8] - 2026-06-17
- Drag & drop to reorder rules.
- Homebrew distribution pipeline.
- Tray icon rebuilds on theme change, with a status dot.

## [0.1.0-alpha.7] - 2026-06-16
- Fixed a bad release ID in the publish workflow.

## [0.1.0-alpha.6] - 2026-06-16
- Date-based rule conditions.
- Launch at login preference.
- Integration tests; public module boundaries for testability.

## [0.1.0-alpha.5] - 2026-06-16
- Versioning fix in the release pipeline.

## [0.1.0-alpha.4] - 2026-06-15
- Prevented undoing activity newer than the undo target.
- Refactored rule application to run on folder update/toggle.
- Auto-focus the new rule title field; pause watcher during update checks.

## [0.1.0-alpha.3] - 2026-06-15
- Update checks run on app launch and every 4 hours.
- Persisted app settings, including paused/watching state.

## [0.1.0-alpha.2] - 2026-06-15
- Fixed the release tag; settings panel now shows the running version
  dynamically instead of a hardcoded string.

## [0.1.0-alpha.1] - 2026-06-15
- Action history with undo support.
- Rule recursion depth limits and scoped evaluation.
- Auto-update support and a release workflow.

## [0.1.0-alpha] - 2026-06-15
- First tagged release: rule engine (name, extension, kind, size, color
  label, custom tags), preview before running rules, tray icon with status
  indicator, CI and release workflows.
