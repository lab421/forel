// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import AppKit

/// Closing the window hides it instead of quitting; Forel keeps running in
/// the menu bar. Quit is only available from the status item menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusBarController: StatusBarController?
    private var model: AppModel?
    private var updater: UpdaterManager?

    /// `@NSApplicationDelegateAdaptor` requires a zero-argument initializer;
    /// the app's model/updater are handed in afterward once SwiftUI has
    /// constructed them, from `ForelMacApp`'s `onAppear`.
    func configure(model: AppModel, updater: UpdaterManager) {
        self.model = model
        self.updater = updater
        model.applyDockIconPreference()
        configureMainWindow()
        if statusBarController == nil {
            setUpStatusBar()
        }
        showMainWindowOnFirstLaunch()
    }

    /// A brand-new install otherwise only shows up as a menu bar icon
    /// (LSUIElement apps don't reliably get focus/visibility on launch),
    /// so a first-time user could easily miss that Forel is running at
    /// all. Surface the main window once, on the rules home, so they land
    /// somewhere they can see and start using right away.
    private func showMainWindowOnFirstLaunch() {
        guard let model else { return }
        guard (try? model.db.getSetting("has_launched_before")) == nil else { return }
        try? model.db.setSetting("has_launched_before", "1")
        model.detailRoute = .rules
        openMainWindow()
        enableLaunchAtLoginByDefault()
    }

    /// Opt-in by default on first install — a folder watcher that isn't
    /// running after a reboot isn't doing its job. The Settings toggle
    /// (and its own `launch_at_login` setting) stays the single source of
    /// truth from here on; this only seeds it once.
    private func enableLaunchAtLoginByDefault() {
        guard let model else { return }
        try? model.db.setSetting("launch_at_login", "1")
        LoginItem.setEnabled(true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if warnAndQuitIfRunningFromDiskImage() {
            return
        }

        // Running as a bare dev executable (no packaged .app/Info.plist) shows
        // a generic Dock icon otherwise; set it explicitly from the bundled artwork.
        if let appIcon = AppIcons.appIcon {
            NSApp.applicationIconImage = appIcon
        }

        if let window = NSApp.windows.first {
            configureMainWindow(window)
        }
        model?.applyDockIconPreference()
        if model != nil, updater != nil {
            setUpStatusBar()
        }
    }

    private func configureMainWindow() {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        configureMainWindow(window)
    }

    private func configureMainWindow(_ window: NSWindow) {
        window.delegate = self
        window.title = "Forel"
        window.titleVisibility = .hidden
    }

    /// Opening Forel straight from the mounted installer disk image (before
    /// dragging it to Applications) is the most common way a first launch
    /// ends up somewhere macOS gates behind a permission prompt — `/Volumes`
    /// is TCC-protected the same way Documents/Desktop/Downloads are, so
    /// just starting up from there is enough to trigger it, regardless of
    /// what Forel's own code does. It also breaks the self-updater, which
    /// needs to write to wherever the app bundle lives. Catch it before any
    /// of that runs and ask the user to move it first instead.
    private func warnAndQuitIfRunningFromDiskImage() -> Bool {
        guard Bundle.main.bundleURL.path.hasPrefix("/Volumes/") else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move Forel to Applications first"
        alert.informativeText = "Forel is running from the installer disk image. Drag Forel into your Applications folder, then open it from there."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        openMainWindow()
        return true
    }

    private func setUpStatusBar() {
        guard let model, let updater else { return }
        statusBarController = StatusBarController(
            model: model,
            updater: updater,
            window: NSApp.windows.first
        )
    }

    private func openMainWindow() {
        let targetWindow = NSApp.windows.first { !($0 is NSPanel) }
        WindowActivation.activateSoon(targetWindow, showsDockIcon: model?.showDockIcon != false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
