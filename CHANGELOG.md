# Changelog

All notable changes to Forel are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.0.1-beta.1] - 2026-06-17

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
- Versioning resets to `0.0.x` for this Swift-native line, to mark it as a
  distinct lineage from the Tauri-era `0.1.0-alpha.x` releases below rather
  than implying continuity with that codebase.

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
