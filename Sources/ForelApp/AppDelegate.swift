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
            window.delegate = self
            window.title = "Forel"
        }
        if model != nil, updater != nil {
            setUpStatusBar()
        }
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
        // Called synchronously from SwiftUI's onAppear, while the window is
        // still mid-appearance: activating right here races the window
        // server and can leave Forel behind whatever app was frontmost.
        // Deferring a tick (and again shortly after, since the regular/
        // accessory policy switch itself needs a moment to take effect)
        // matches what `WindowActivationBridge` already does elsewhere.
        DispatchQueue.main.async {
            WindowActivation.activate(targetWindow)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            WindowActivation.activate(targetWindow)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
