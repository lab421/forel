<div align="center">

<img src="assets/forel-icon.png" alt="Forel" width="120" />

# Forel

**The Hazel alternative for macOS. Free and open source.**

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?style=flat-square&logo=swift)](https://www.swift.org)
[![Downloads](https://img.shields.io/github/downloads/lab421/forel/total?style=flat-square)](https://github.com/lab421/forel/releases)
[![License: GPLv3](https://img.shields.io/badge/License-GPLv3-blue?style=flat-square)](LICENSE)

<br/>

This project is built and maintained for free, on personal time. A ⭐ on the repo is the simplest way to say thanks and helps Forel get discovered by others who might need it. For anyone who wants to go further, you can support the work with a [buy me a coffee](https://buymeacoffee.com/lionelguic9) ☕ 



<img src="assets/app-screen-new-1.png" alt="Forel — main view" width="49%" /> <img src="assets/app-screen-new-2.png" alt="Forel — rule editor" width="49%" />

</div>


> **Free, open source, and 100% on-device, local, no account, no subscription, no telemetry.**

**Install with [Homebrew](https://brew.sh):**

```sh
brew install --cask lab421/tap/forel
```

## Why Forel

Forel is a free, open-source, community-driven take on folder automation for macOS.

Define rules once watch folders, match files, and move, rename, tag, or label them automatically then let Forel run quietly in your menu bar.

---

## What Forel does

Forel watches your folders and organizes your files automatically based on rules you define — by filename, extension, kind, size, date, tags, or color label.

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

- **Free & open source** — no license fee, no subscription, GPLv3-licensed.
- **100% on-device** — no cloud, no API keys, no account. Your files never leave your Mac.
- **Rule-based** — match by name, extension, kind, size, date, tags, or color label.
- **Native menu-bar app** — runs quietly in the background; toggle rules without opening the window.
- **Community-driven** — built in the open, contributions welcome.

---

## Features

- **Rule-based automation** — Create flexible rules combining filename patterns, file types, sizes, dates, tags, and Finder color labels.
- **Folder watching** — Monitor any number of folders in real time with native macOS FSEvents.
- **Menu bar app** — Forel lives in your menu bar. Toggle individual rules on/off without opening the main window.
- **Actions** — Move, copy, rename, tag, trash, delete, or run a custom script.
- **SQLite persistence** — Rules, folders, and history are stored locally in a bundled SQLite database.

---

## Installation

### Homebrew

```bash
brew install --cask lab421/tap/forel
```

or

```bash
brew tap lab421/tap
brew install --cask forel
```

### Manual

Download the latest release `.dmg` from the [Releases](https://github.com/lab421/forel/releases) page, open it, and drag Forel to your Applications folder.

### Build from source

**Prerequisites:** [Swift 6](https://www.swift.org) · macOS 14 or later

```bash
git clone https://github.com/lab421/forel.git
cd forel
swift build
swift test
swift run
```

To build and package the app, use the Swift package tooling and the existing release workflow.

> Requires macOS 14 Sonoma or later.

---

## Quick Start

1. Launch Forel — the icon appears in your **menu bar**.
2. Click the icon to see active rules, or open the main window.
3. Click **New Rule** and choose a folder to watch.
4. Define your conditions — by name, extension, kind, size, date, tags, or color label.
5. Set an action: move, rename, tag, copy, or run a script.
6. Enable the rule. Forel handles the rest — even when the window is closed.

---

## Architecture

Forel is built as a native Swift macOS app:

```
forel/
├── Package.swift              # Swift Package Manager manifest
├── Sources/
│   ├── ForelApp/              # SwiftUI app, menu bar, settings, editor, views
│   └── ForelCore/             # Rule engine, watcher, SQLite persistence, models
├── Tests/
│   └── ForelCoreTests/        # Core engine and persistence tests
```

**Key technology choices:**

| Layer | Technology | Why |
|-------|-----------|-----|
| App shell | SwiftUI + AppKit | Native macOS UI with direct control over windows, menu bar, and focus |
| Backend | Swift 6 | Unified app and core logic, strong typing, simple packaging |
| File watching | Native FSEvents wrapper | Low-latency, battery-friendly folder monitoring |
| Database | SQLite | Embedded, no server, predictable schema and queries |
| Persistence layer | Custom Swift database wrapper | Direct control over transactions, migrations, and rule round-trips |
| Updates | GitHub Releases check | Detects new tagged releases; ad-hoc signed builds are updated by manual reinstall, not in-place patching |
| Build | Swift Package Manager | Single toolchain for development, test, and release |

**Execution pipeline:**

```
Input
  - FSEvents (real‑time watcher)
  - Run Now (manual — whole folder)
  - Dry Run / Preview (manual — whole folder)
        ↓
Rule Engine (per file, sorted by cost)
  ├─ Scope check (recursion depth)
  ├─ Condition matching (name, extension, kind,
  │   size, date, tags, color label, contents, …)
  └─ Plan actions (conflict‑aware)
        ↓
Action Executor
  ├─ Move / Copy / Rename
  ├─ Tag / Color label
  ├─ Trash / Delete
  └─ Run Script / Shortcut
        ↓
History / Undo (SQLite)
```

---

## Roadmap

- [x] Folder watching
- [x] Rule engine (name, extension, kind, size, date)
- [x] Actions: move, copy, rename, trash, delete, tag, run script
- [x] SQLite persistence
- [x] Menu bar icon with live rule toggle
- [x] Action history & undo
- [x] Automatic updates
- [x] Preferences: launch at login
- [x] Shortcuts actions
- [x] Drag & drop to reorder rules
- [x] Rules based metadata files
- [x] Activity logs
- [x] Automatic cleaning database
- [ ] Archive / Unarchive actions
- [ ] Compress actions
- [ ] Sync actions
- [ ] Upload actions
- [ ] Native notifications on rule actions
- [ ] AI features

---

## Content matching

The **Contents** condition matches text found *inside* files. Everything is read
locally — no cloud, OCR runs on-device. When a file's text can't be read, the Dry
Run tells you why.

```
File path
  │
  ├─ Known plain text (.txt, .md, .json, …) ────► read as UTF‑8 / UTF‑16 / ISO Latin 1
  │
  ├─ PDF ──► text layer ─(empty)─► Vision OCR (Apple Neural Engine)
  │
  ├─ RTF / .doc/.docx ──► AppKit document reader (main thread)
  │
  ├─ .xlsx / .pptx / .odt/.ods/.odp ──► ZIP → XML → strip tags
  │
  ├─ .pages / .numbers / .key ──► ZIP → Preview.pdf → PDF text
  │
  ├─ Images (.png, .jpg, .heic, …) ──► Vision OCR (Apple Neural Engine)
  │
  ├─ .xls / .ppt / .epub ──► Spotlight query (contains only)
  │
  └─ Unknown extension ──► try plain text ─(binary/undecodable)─► no match
```

| Type | Formats | Limits |
|------|---------|--------|
| Plain text | `.txt` `.md` `.csv` `.tsv` `.json` `.xml` `.yaml` `.yml` `.html` `.css` `.js` `.ts` `.swift` `.rs` `.py` `.rb` `.go` `.java` `.c` `.cpp` `.h` `.log`, plus any other text file (`.ini`, `.conf`, no extension, …) | 50 MB |
| PDF | `.pdf` (text layer, or OCR for scanned PDFs) | 100 MB / 100 pages · OCR 20 pages |
| Rich text | `.rtf` `.rtfd` | — |
| Word | `.doc` `.docx` | — |
| Excel | `.xlsx` | 100 MB |
| PowerPoint | `.pptx` | 100 MB |
| Apple iWork | `.pages` `.numbers` `.key` | 100 MB |
| OpenDocument | `.odt` `.ods` `.odp` | 100 MB |
| Images (OCR) | `.png` `.jpg` `.jpeg` `.heic` `.tiff` `.tif` | 25 MB / 12000 px |
| Spotlight fallback | `.xls` `.ppt` `.epub` | `contains` only |

> [!NOTE]
> **Apple iWork** files are read from the preview the app saves inside the
> document; one saved without a preview falls back to Spotlight.
>
> The **Spotlight fallback** is used for formats Forel can't read directly. It
> relies on macOS having already indexed the file and can only answer the
> `contains` operator (not `is`, `starts with`, regex, …). When a file isn't
> indexed, it simply doesn't match.
>
> Unsupported files simply don't match the Contents condition.

## Contributing

Forel is in early development and contributions are very welcome.

```bash
git clone https://github.com/lab421/forel.git
cd forel
swift build
swift test
```

Please read the repository guidelines before submitting. Bug reports, feature requests, and documentation improvements are all appreciated.

---

## License

The source code is licensed under **GPL-3.0-or-later**, copyright © 2026 lab421 — see [LICENSE](LICENSE). That license covers the source code only.

The **Forel** name, logo, and look are **not** covered by the GPL and are protected separately — see [TRADEMARKS.md](TRADEMARKS.md).

---

## Star History

<a href="https://star-history.com/#lab421/forel&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=lab421/forel&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=lab421/forel&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=lab421/forel&type=Date" />
  </picture>
</a>

---

<div align="center">

Made with ☕ · SwiftUI + SQLite · Inspired by file automation workflows popularized by tools like Hazel.

</div>
