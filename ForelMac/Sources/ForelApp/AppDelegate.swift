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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running as a bare dev executable (no packaged .app/Info.plist) shows
        // a generic Dock icon otherwise; set it explicitly from the bundled artwork.
        if let appIcon = AppIcons.appIcon {
            NSApp.applicationIconImage = appIcon
        }

        if let window = NSApp.windows.first {
            window.delegate = self
        }
        if model != nil {
            setUpStatusBar()
        }
    }

    private func setUpStatusBar() {
        guard let model else { return }
        statusBarController = StatusBarController(
            model: model,
            window: NSApp.windows.first
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
