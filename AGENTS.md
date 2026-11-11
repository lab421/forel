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
./build.sh strings   # update Localization/Localizable.xcstrings
```

## Localization

Forel is written in English and translated into French, Spanish, and German. It follows the language set in macOS unless the user picks one in Settings > General > Language, which writes the same per-app preference as System Settings > General > Language & Region > Applications (`AppLanguage`). The languages offered come from the app's `.lproj` folders, so a language added to the catalog appears there automatically.

- All UI text lives in `Localization/Localizable.xcstrings` (one String Catalog, every language). The privacy texts of `Info.plist` are in `Localization/InfoPlist.xcstrings`; keep their English in sync with `write_info_plist` in `build.sh`.
- `build.sh` compiles the catalogs into the app's own `Contents/Resources/<language>.lproj`. They are deliberately not SwiftPM resources: SwiftPM's native build system copies a catalog without compiling it, and SwiftUI and `String(localized:)` look in the main bundle, not the package's resource bundle.
- After adding, changing, or removing user-facing text, run `./build.sh strings`, translate the new keys into every language of the catalog (with their plural forms), and commit the catalog. CI runs `./build.sh strings --check`: it fails when the catalog is out of date and warns about strings a language doesn't translate yet, which the app then shows in English.
- Translations follow Apple's terminology for each language (Finder, System Settings, Trash…) and address the user the way macOS does: "vous" in French, "tú" in Spanish, "du" in German. Keep `{tokens}`, `$FOREL_FILE`, and format specifiers as they are; use positional specifiers (`%1$@`, `%2$@`) when a translation changes their order.
- Write user-facing text so it can be translated:
  - SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`) are localizable as is. `Text(someString)` is shown verbatim: a `String` must already be localized. A custom view that shows a caller's text takes a `LocalizedStringKey` (or a `Text`), not a `String`.
  - Text built outside SwiftUI uses `String(localized: "…", comment: "…")` in ForelApp, and `String(localized: "…", bundle: .forelStrings, comment: "…")` in ForelCore. `swift test` has no app bundle, so tests that check text with a count call `CompiledStrings.install()` in their suite's `init` to compile and use the catalog.
  - One key per sentence with interpolation; never concatenate fragments, and never compare displayed text in code. Plurals are variations of a single key (`"\(count) items checked"`), never `count == 1 ? "" : "s"`. `./build.sh strings` adds the key but not its variations: add the English `one` form in the catalog (Xcode's String Catalog editor, "Vary by Plural").
  - Use `.textCase(.uppercase)` rather than `.uppercased()`, and `FormatStyle` for displayed dates, numbers, and sizes.
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
