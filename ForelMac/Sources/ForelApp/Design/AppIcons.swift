import AppKit

/// Bundled brand assets: the full-colour Forel leaf app icon and the white
/// glyph used in the menu bar (`Resources/AppIcon.png`, `Resources/TrayIcon.png`
/// — copied from the Tauri app's `assets/forel-icon.png` and
/// `src-tauri/icons/tray-icon.png` so both versions ship the same artwork).
enum AppIcons {
    static let appIcon: NSImage? = loadImage("AppIcon")
    /// White-on-transparent leaf glyph, sized down for the menu bar.
    static let trayGlyph: NSImage? = loadImage("TrayIcon")

    private static func loadImage(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
