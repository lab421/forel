# Forel - AI & Agent Guidelines

> Source of truth for AI coding agents working on the Swift app in this repository.
> The previous Tauri/React implementation is archived in `tauri/`.

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
├── tauri/          # archived Tauri + React implementation
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

## Persistence and rules

- Rules, conditions, actions, and history are stored in SQLite.
- The rule engine lives in `Sources/ForelCore/Engine`.
- UI changes that affect persistence should be backed by tests in `Tests/ForelCoreTests`.

## Build and test commands

```bash
swift build
swift test
swift run ForelApp
```

## Notes for contributors

- Keep the codebase macOS-only.
- Prefer the existing Swift patterns in the repo over introducing new abstractions.
- When a UI change affects saved rules or execution behavior, verify the database round-trip and execution path together.
