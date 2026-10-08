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
    /// Set by `ForelMacApp` as soon as the model and updater exist, so the
    /// menu bar icon can be created at launch instead of waiting for the main
    /// window's `onAppear`: macOS doesn't open that window when it starts
    /// Forel as a login item, so `onAppear` only fires once the user opens it.
    static var launchContext: (model: AppModel, updater: UpdaterManager)?

    var statusBarController: StatusBarController?
    private var model: AppModel?
    private var updater: UpdaterManager?
    /// The window hosting `ContentView`, reported by `ForelMacApp` through
    /// `mainWindowDidAttach`. Tracked explicitly rather than looked up in
    /// `NSApp.windows`, which also holds the menu bar item's own window and
    /// the Settings window, in no useful order.
    private weak var mainWindow: NSWindow?
    /// The main window was asked for before it existed (Forel started as a
    /// login item); bring it forward as soon as SwiftUI has created it.
    private var activatesMainWindowWhenAttached = false

    /// `@NSApplicationDelegateAdaptor` requires a zero-argument initializer;
    /// the app's model/updater are handed in afterward once SwiftUI has
    /// constructed them, from `ForelMacApp`'s `onAppear` (or from
    /// `launchContext` at launch, whichever comes first).
    func configure(model: AppModel, updater: UpdaterManager) {
        self.model = model
        self.updater = updater
        model.applyDockIconPreference()
        setUpStatusBar()
        showMainWindowOnFirstLaunch()
    }

    /// Called whenever `ContentView` lands in a window — at launch, or later
    /// when the window is first created by reopening a login-item launch.
    func mainWindowDidAttach(_ window: NSWindow) {
        mainWindow = window
        window.delegate = self
        window.title = "Forel"
        window.titleVisibility = .hidden
        if activatesMainWindowWhenAttached {
            activatesMainWindowWhenAttached = false
            WindowActivation.activateSoon(window, showsDockIcon: model?.showDockIcon != false)
        }
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

        if model == nil, let context = Self.launchContext {
            model = context.model
            updater = context.updater
        }

        // Running as a bare dev executable (no packaged .app/Info.plist) shows
        // a generic Dock icon otherwise; set it explicitly from the bundled artwork.
        if let appIcon = AppIcons.appIcon {
            NSApp.applicationIconImage = appIcon
        }

        // The status item doesn't exist yet, so the only window there can be
        // at this point is the main one.
        if mainWindow == nil, let window = NSApp.windows.first {
            mainWindowDidAttach(window)
        }
        model?.applyDockIconPreference()
        setUpStatusBar()
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
        guard mainWindow != nil else {
            // Returning true lets SwiftUI create the window it skipped at
            // launch; `mainWindowDidAttach` then brings it forward.
            activatesMainWindowWhenAttached = true
            return true
        }
        // The window exists but is hidden: show it ourselves, and return
        // false so SwiftUI doesn't open a second one next to it.
        openMainWindow()
        return false
    }

    private func setUpStatusBar() {
        guard statusBarController == nil, let model, let updater else { return }
        statusBarController = StatusBarController(
            model: model,
            updater: updater,
            onOpenMainWindow: { [weak self] in self?.openMainWindow() }
        )
    }

    private func openMainWindow() {
        guard let mainWindow else {
            // Started as a login item, Forel has no main window yet; reopening
            // the app is what makes SwiftUI create it.
            activatesMainWindowWhenAttached = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        WindowActivation.activateSoon(mainWindow, showsDockIcon: model?.showDockIcon != false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
