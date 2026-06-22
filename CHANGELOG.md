# Changelog

All notable changes to Forel are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Added an Import to Library action that can add files to the Music, Photos, or TV native macOS libraries. When a file is already present you can choose to skip it (leave the library untouched) or replace it (remove the existing entry before re-importing). File format compatibility is checked before each import, and importing into Photos requires granting access in System Settings.
- The Contents condition now uses on-device Vision OCR and the Apple Neural Engine to extract text from scanned PDFs and images — everything stays private and works offline, with no data sent to the cloud.
- Added image OCR support for WebP, GIF, BMP, JPEG 2000, and Photoshop files.
- Added content extraction support for Office template formats (.dotx, .xltx, .potx).
- Added a Permissions section to Settings showing the status of Photos and Music/TV automation access, with buttons to grant access or open the relevant System Settings pane.

### Changed
- Activity and Dry Run text (file paths, messages, rule names) can now be selected and copied.
- Import to Library now only offers Skip and Replace as conflict options (Rename removed), with Skip as the default.
- The action kind and condition kind pickers now show SF Symbol icons and are grouped into labelled sections.

## [1.0.0] - 2026-06-21

🎉🍾 **Forel is exiting beta.** This release marks the transition to a stable. Faster, safer, and ready for everyday use.

### Added
- Added an options button to the Rename action with a "Clean file name" toggle that strips accents and special characters, lowercases, and converts camelCase and spaces to hyphens.
- Added a directory filter and paginated loading to Activity so large histories open faster.
- Added an option to Move to Folder and Copy to Folder rules for handling a file that already exists at the destination: rename the new file (default), replace the existing file (sent to the Trash, not deleted), or skip the file to avoid creating a duplicate.
- Added a History retention setting to limit stored activity entries, with automatic background cleanup of entries older than the configured number of days.

### Changed
- Dry Run, Run Now, and the automatic watcher now always agree on what a rule would do to a file, including which files are skipped, blocked, or already sorted — no more surprises between a preview and what actually happens.
- Undo now refuses to act if the file changed since the original action, or if an active rule would immediately reprocess the restored file, instead of silently restoring the wrong file or letting the watcher redo what was just undone.
- Copy to Folder is no longer undoable — a copy is an independent file once created, not something to roll back.
- The action options button in the rule editor is now hidden for actions that have no options instead of showing an empty popover.
- Database upgrades now run through an ordered migration list to keep future updates safer.

### Fixed
- Fixed a rare crash in automatic history cleanup caused by unsynchronized database access from background threads.
- Fixed history retention cleanup incorrectly comparing dates across timezones — dates are now always stored and compared in UTC.
- Fixed the watcher re-evaluating every file once after migrating to the new path-state schema, instead of trusting a matching fingerprint.
- Fixed Run Script actions hanging forever when the script doesn't exit — they now time out after 60 seconds.
- Delete now permanently removes the file instead of moving it to the Trash (undo is no longer available for Delete).
- Fixed rename patterns containing `/` being able to move files outside the source directory — they now produce an error instead.
- Rename patterns are now validated against macOS filename rules (`.`, `..`, trailing spaces/dots, max length) and show live warnings in the editor.
- Fixed Dry Run showing an empty action area instead of explaining when a matched rule has no actions.
- Fixed Activity becoming unresponsive when opening very large history logs.
- Fixed renamed or moved files being immediately reprocessed by the watcher and receiving repeated rename suffixes.
- Fixed Dry Run crashing when a very large folder produced too many preview matches.
- Fixed rules stopping after a successful Move to Folder action instead of continuing with later actions on the moved file.
- Fixed Dry Run showing rename actions as unavailable after a simulated move when the rename pattern only used the file name.
- Fixed unreadable rule editor selectors in Light mode.
- Fixed Dry Run hiding files that matched a rule with conditions but no actions.
- Fixed a bug where a destination conflict could rename a file mid-move into a numbered duplicate that Dry Run never showed.
- Fixed the automatic watcher repeatedly re-running a Copy to Folder rule on the same untouched file, flooding Activity with duplicate entries.
- Fixed the automatic watcher logging a spurious "doesn't exist" entry for a file it had just successfully moved, caused by a duplicate filesystem notification for the same change.

## [0.1.0-beta.5] - 2026-06-19

### Added
- Added a Run Shortcut rule action that lists macOS Shortcuts and lets each action choose matched-file or no-input mode.
- Added a Settings toggle to show or hide Forel's Dock icon while the app keeps running.
- Added drag-and-drop reordering for watched folders in the sidebar.

### Fixed
- Fix hidden title window
- Adding an already-watched folder now shows a clear explanation instead of a database error.

## [0.1.0-beta.4] - 2026-06-18

### Added
- Added metadata conditions for matching files by download website and download app, backed by macOS where-from metadata.
- The Contents condition now matches text inside PDFs (including scanned PDFs via OCR), Word documents, Excel spreadsheets (.xlsx), PowerPoint presentations (.pptx), Apple iWork documents (Pages, Numbers, Keynote), OpenDocument files (.odt, .ods, .odp), RTF files, and images (via OCR), and the Dry Run shows which content was read.
- The Contents condition can also match other indexed formats (.xls, .ppt, Pages, Numbers, Keynote, OpenDocument, EPUB) through the macOS Spotlight index, for "contains" matching when the file has been indexed.

### Changed
- The rule editor now warns that all-level subfolder scans can slow execution in folders with many files.

### Fixed
- Dry Run and Run Now no longer scan nested folders when only current-folder rules are enabled.
- The main window now has a larger minimum size so rule controls stay visible when resized.

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
