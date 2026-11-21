# Forel - AI & Agent Guidelines

> Source of truth for AI coding agents working on the Swift app in this repository.

## What Forel is

Forel is a native macOS file-automation app. It watches folders and runs user-defined rules on files locally. The active app is the Swift package at the repository root.

## Stack

| Layer | Technology |
|---|---|
| App shell | SwiftUI / AppKit |
| Backend | Swift 6 |
| Core persistence | SQLite via the in-house `Database` wrapper |
| File watching | `FileWatcher` / FSEvents on macOS |
| Updates | GitHub Releases check (`UpdaterManager`) |
| Build | Swift Package Manager |

## Repository layout

```text
forel/
├── Package.swift
├── Sources/
│   ├── ForelApp/
│   └── ForelCore/
├── Tests/
└── README.md
```

## Working rules

- Use `swift build` and `swift test` from the repository root.
- When changing Swift code, keep edits aligned with the existing package structure and avoid unnecessary refactors.
- Use `apply_patch` for manual file edits.
- Do not revert user changes you did not make.
- Avoid destructive commands unless explicitly requested.

## App structure

- `Sources/ForelApp` contains the SwiftUI app, windows, views, and menu bar code.
- `Sources/ForelCore` contains models, persistence, watcher, and rule engine logic.
- `Tests/ForelCoreTests` contains the core unit tests. Add or update tests with behavior changes.

## Execution pipeline

```
Input (FSEvents / Run Now / Dry Run)
        ↓
Rule Engine (per file)
  ├─ Scope check (recursion depth)
  ├─ Condition matching (sorted by evaluation cost)
  └─ Plan actions (conflict‑aware, plan‑before‑act)
        ↓
Action Executor (execute or skip)
        ↓
History / Undo (SQLite)
```

All three execution paths (Dry Run, Run Now, watcher) share the same `plan()`
logic — only Dry Run skips `execute()`. `previewFile()` and `run()` both use a
`PendingFile` queue for chain processing (copies enqueued, renames update path).

## Persistence and rules

- Rules, conditions, actions, and history are stored in SQLite via the in-house `Database` wrapper.
- The rule engine lives in `Sources/ForelCore/Engine`.
- UI changes that affect persistence should be backed by tests in `Tests/ForelCoreTests`.
- Any change to rule behavior **or** to core file-system-touching internals —
  folder enumeration (`RuleEngine.walkEntriesInner`), file filtering/exclusion
  (`SystemFileFilter`), watcher event handling (`FileWatcher`), action
  execution, scope, recursion depth, matching, action chains — must be
  checked across all three execution paths: Dry Run preview, manual Run Now,
  and automatic watcher execution. These share most of their underlying code,
  but not all of it, so it's easy to fix or change something on one path
  (e.g. the watcher) and forget the others (e.g. Dry Run's folder scan).
  Include tests or explicit verification that all three stay consistent.

## Build and test commands

```bash
swift build
swift test
swift run ForelApp
```

## Localization

Forel is written in English and translated into French, Spanish, and German. It follows the language set in macOS unless the user picks one in Settings > General > Language, which writes the same per-app preference as System Settings > General > Language & Region > Applications (`AppLanguage`). The languages offered come from the `.lproj` folders in `Localization/`, so a language added there appears automatically.

- Each language has one key/value file, `Localization/<language>.lproj/Localizable.strings`, grouped by screen with `//` comments. All four files have the same sections and keys in the same order; `en.lproj` is the reference.
  ```
  // Settings
  "settings_language" = "Langue";
  "settings_relaunch_now" = "Relancer maintenant";
  ```
  `InfoPlist.strings`, next to it, holds the privacy texts of `Info.plist`; keep their English in sync with `write_info_plist` in `build.sh`.
- Keys are `snake_case`, prefixed by the screen or area (`sidebar_`, `rule_editor_`, `settings_`, `action_plan_`…). Text shared by several screens goes in `// Common` without a prefix (`cancel`, `save`).
- Code reads text with `L10n.string("key", args…)` (`Sources/ForelCore/L10n.swift`), in ForelApp and ForelCore alike. SwiftUI takes the result as a `String`: `Text(L10n.string("sidebar_watching"))`, `Button(L10n.string("cancel"))`, `.help(L10n.string("…"))`. Never write a SwiftUI literal like `Text("Watching")`: it would stay in English. Text that is not translated (`"\(count)"`, a file name) uses `Text(verbatim:)`.
- Values only use `%@` for arguments; use `%1$@`, `%2$@` when a translation changes their order. Integers are passed as is and shown formatted for the language ("5 000").
- Plurals are two keys, `key_one` and `key_other`, read with `L10n.plural("key", count, args…)`: the count is the first `%@`, other arguments follow. A singular form may leave the number out ("Copy Rule"). The rule deciding which form applies is in `L10n.usesOneForm` (0 is singular in French); a language with more plural forms needs its rule there.
- `build.sh` checks each file with `plutil -lint` and copies the `.lproj` folders into the app's own `Contents/Resources`. They are deliberately not SwiftPM resources: Foundation looks in the main bundle. `swift test` (a debug build without that bundle) reads English from `Localization/en.lproj` directly.
- `LocalizationFilesTests` fails when a key the code uses is missing from English, when English has a key the code no longer uses, when a language misses or adds a key, when a key is written twice, when a translation loses a placeholder, or when ForelApp has a hard-coded SwiftUI literal. So after adding, changing, or removing text: add the key to every language file, in the same section, and translate it.
- To add a language, copy `en.lproj` to `<code>.lproj`, translate the values, and add its plural rule to `L10n.usesOneForm` if it differs.
- Translations follow Apple's terminology for each language (Finder, System Settings, Trash…) and address the user the way macOS does: "vous" in French, "tú" in Spanish, "du" in German. Keep `{tokens}`, `$FOREL_FILE`, and `%@` placeholders as they are.
- One key per sentence with arguments; never concatenate fragments, and never compare displayed text in code. Use `.textCase(.uppercase)` rather than `.uppercased()`, and `FormatStyle` for displayed dates, numbers, and sizes.
- Never translate text that ends up on disk or in stored data: folder and file names produced by actions (`{kind}`, `{extension}`'s "No Extension", date formats), destination tokens, and the user's own data.

## Changelog

- New entries always go under `## [Unreleased]` at the top of `CHANGELOG.md`, never directly under a version header. A version header is only created by renaming `[Unreleased]` when actually cutting that release.
- Entries must be concise, precise, and user-facing: state what changed and the user-visible effect, no filler, no internal implementation detail (no file/function names, no "we").

## UX & design guidelines

Forel's UI should feel like it belongs on the user's Mac, not like a
cross-platform app that happens to run on macOS. When adding or changing UI:

- Follow the current [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)
  for macOS — standard control sizes, spacing, and SF Symbols rather than
  custom-drawn equivalents, unless the existing design system
  (`Sources/ForelApp/Theme.swift`, `Components.swift`) already defines one.
- Prefer native SwiftUI/AppKit components and behaviors (sheets, popovers,
  menus, `.alert`, drag-and-drop, keyboard shortcuts) over hand-rolled ones.
  A custom control is justified only when no native one fits.
- Support both Light and Dark mode, and Dynamic Type where practical — verify
  contrast and readability in both appearances, not just the one in your
  screenshot.
- Every destructive or hard-to-reverse action (delete, clear history,
  irreversible undo) needs a clear, specific confirmation or warning — never
  a generic "Are you sure?".
- Long-running work (Run Now, Dry Run on large folders) must show progress or
  a loading state; the UI should never appear frozen or unresponsive.
- Errors and blocked actions (e.g. an unsafe undo) get a plain-language
  explanation of *why*, not just a generic failure message.
- Favor progressive disclosure: keep the default view simple, push advanced
  options (e.g. action options popovers) behind an explicit, discoverable
  affordance — and hide that affordance entirely when there's nothing to show
  (see `ActionKind.hasOptions`).
- Text the user might want to copy (file paths, error messages, history
  entries) should be selectable, not just displayed.
- When in doubt, match how a well-built native Mac app already solves the
  same problem (Finder, Mail, System Settings) rather than inventing a new
  pattern.

## Notes for contributors

- Keep the codebase macOS-only.
- Prefer the existing Swift patterns in the repo over introducing new abstractions.
- When a UI change affects saved rules or execution behavior, verify the database round-trip and execution path together.
