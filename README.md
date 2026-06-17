<div align="center">

<img src="assets/forel-icon.png" alt="Forel" width="120" />

# Forel

**The Hazel alternative for macOS. Free and open source.**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Tauri 2](https://img.shields.io/badge/Tauri-2-24c8db?style=flat-square&logo=tauri)](https://tauri.app)
[![Rust](https://img.shields.io/badge/Rust-2021-orange?style=flat-square&logo=rust)](https://www.rust-lang.org)
[![React 19](https://img.shields.io/badge/React-19-61dafb?style=flat-square&logo=react)](https://react.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Stars](https://img.shields.io/github/stars/forel-app/forel?style=flat-square)](https://github.com/forel-app/forel/stargazers)
[![Status](https://img.shields.io/badge/status-alpha-red?style=flat-square)](https://github.com/forel-app/forel)

[Download](#installation) · [Documentation](docs/) · [Contributing](CONTRIBUTING.md)

<br/>

<img src="assets/app-screen-1.png" alt="Forel — main view" width="49%" /> <img src="assets/app-screen-2.png" alt="Forel — rule editor" width="49%" />

</div>

> [!WARNING]
> Forel is currently in **alpha**. Expect bugs, missing features, and breaking changes between versions. Not recommended for production use yet.

---

> **Free, open source, and 100% on-device.**
> Forel sorts your files by rules you define — they never leave your Mac.

---

## Why Forel

Forel is a free, open-source, community-driven take on folder automation for macOS. Define rules once — watch folders, match files, and move, rename, tag, or label them automatically — then let Forel run quietly in your menu bar.

---

## What Forel does

Forel watches your folders and organizes your files automatically based on rules you define — by filename, extension, size, or date.

```
Downloads/
├── invoice_march_2026.pdf     →  Work/Invoices/2026/
├── photo_2026-03-14.jpg       →  Photos/2026/March/
├── contract_draft_v3.docx     →  Work/Legal/Pending/
└── bank_statement_march.pdf   →  Finance/2026/
```

Set up a rule once. Forel handles the rest — even when the window is closed.

And everything happens **on your Mac**. No cloud. No API keys. No subscription. Your files never leave your machine.

---

## Highlights

- **Free & open source** — no license fee, no subscription, MIT-licensed.
- **100% on-device** — no cloud, no API keys, no account. Your files never leave your Mac.
- **Rule-based** — match by name, extension, kind, size, date, tags, color label, or content.
- **Native menu-bar app** — runs quietly in the background; toggle rules without opening the window.
- **Community-driven** — built in the open, contributions welcome.

---

## Features

- **Rule-based automation** — Create flexible rules combining filename patterns, file types, sizes, and dates.
- **Folder watching** — Monitor any number of folders in real time using the `notify` crate (FSEvents-backed on macOS).
- **Menu bar icon** — Forel lives in your menu bar. Toggle individual rules on/off without opening the main window.
- **Actions** — Move, copy, rename, tag, trash, or run a custom script.
- **Privacy first** — No telemetry, no analytics, no accounts. SQLite database stored locally.

---

## Installation

### Homebrew

```bash
brew tap forel-app/forel
brew install --cask forel
```

### Manual

Download the latest `.dmg` from the [Releases](https://github.com/forel-app/forel/releases) page, open it, and drag Forel to your Applications folder.

### Build from source

**Prerequisites:** [Rust](https://rustup.rs) · [Node.js 20+](https://nodejs.org) · [pnpm](https://pnpm.io)

```bash
git clone https://github.com/forel-app/forel.git
cd forel
pnpm install
pnpm tauri dev
```

To build a release `.dmg`:

```bash
pnpm tauri build
```

> Requires macOS 14 Sonoma or later.

---

## Quick Start

1. Launch Forel — the icon appears in your **menu bar**.
2. Click the icon to see active rules, or open the main window.
3. Click **Add Rule** and choose a folder to watch.
4. Define your conditions — by name, extension, size, date, or content.
5. Set an action: move, rename, tag, or run a script.
6. Enable the rule. Forel handles the rest — even when the window is closed.

For a full walkthrough, see the [Getting Started guide](docs/getting-started.md).

---

## Architecture

Forel is built with [Tauri 2](https://tauri.app): a **Rust backend** for system-level work and a **React frontend** for the UI, compiled into a native macOS app.

```
forel/
├── src/                        # React + TypeScript frontend
│   ├── components/
│   │   ├── RuleList.tsx         # Rules list view
│   │   ├── RuleEditor.tsx       # Rule detail / editor
│   │   └── Sidebar.tsx          # Folder sidebar
│   ├── store/
│   │   └── index.ts             # Zustand global state
│   └── types/
│       └── index.ts             # Shared TypeScript types
│
└── src-tauri/                  # Rust backend
    ├── src/
    │   ├── lib.rs               # App setup, Tauri builder
    │   ├── state.rs             # Shared AppState (DB + watcher)
    │   ├── commands.rs          # Tauri IPC commands (invokable from frontend)
    │   ├── db.rs                # SQLite schema & queries (rusqlite)
    │   ├── tray.rs              # macOS menu bar icon & menu
    │   ├── watcher.rs           # File system watcher (notify crate)
    │   └── rules/
    │       ├── model.rs         # Rule / Condition / Action data models
    │       ├── engine.rs        # Rule evaluation pipeline
    │       ├── condition.rs     # Condition matching logic
    │       └── action.rs        # Action execution (move, rename, tag…)
    ├── Cargo.toml
    └── tauri.conf.json
```

**Key technology choices:**

| Layer | Technology | Why |
|-------|-----------|-----|
| App shell | Tauri 2 | Native macOS binary, tiny bundle, no Electron overhead |
| Backend | Rust | Safe systems code, direct FSEvents access, zero-cost async |
| File watching | `notify` 6 (FSEvents) | Low-latency, battery-friendly folder monitoring |
| Database | SQLite via `rusqlite` | Embedded, no server, persists rules across reboots |
| Frontend | React 19 + TypeScript | Familiar web stack, fast iteration |
| State | Zustand | Minimal, no boilerplate |
| Build | Vite 7 + pnpm | Fast HMR during development |

---

## Roadmap

- [x] Folder watching (FSEvents via `notify`)
- [x] Rule engine (name, extension, size, date)
- [x] Actions: move, copy, rename, trash, delete, tag, open with, run script
- [x] SQLite persistence
- [x] macOS menu bar icon with live rule toggle
- [x] Action history & undo
- [x] Automatic updates
- [x] Preferences: launch at login
- [ ] Sync actions
- [ ] Upload actions
- [ ] Native notifications on rule actions
- [ ] Activity logs
- [ ] Drag & drop to reorder rules
- [ ] Rules based metadata files
- [ ] Automatic cleaning database
- [ ] AI features

---

## Contributing

Forel is in early development and contributions are very welcome.

```bash
git clone https://github.com/forel-app/forel.git
cd forel
pnpm install
pnpm tauri dev   # hot-reload frontend + Rust backend
```

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting. Bug reports, feature requests, and documentation improvements are all appreciated.

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

<div align="center">

Made with ☕ · Tauri + Rust + React · Inspired by file automation workflows popularized by tools like Hazel.

</div>
