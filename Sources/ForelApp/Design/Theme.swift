import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Glass palette for the menu-bar quick panel and main window. Colours are
/// dynamic so the user's Light/Dark/System setting can drive every view.
@MainActor
enum ForelTheme {
    static let background = Color(light: NSColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1),
                                  dark: NSColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1))
    /// Mutable so the user can change it from Settings; defaults to the same
    /// system blue (#0A84FF) used as the accent in the Tauri version.
    static var accent: Color = AccentPreset.blue.color
    static let success = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let primaryText = Color(light: NSColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1),
                                   dark: .white)
    static let secondaryText = Color(light: NSColor(red: 0.38, green: 0.40, blue: 0.46, alpha: 1),
                                     dark: NSColor(white: 1, alpha: 0.55))
    static let divider = Color(light: NSColor(white: 0, alpha: 0.08),
                               dark: NSColor(white: 1, alpha: 0.08))
    static let surface = Color(light: NSColor(white: 1, alpha: 0.72),
                               dark: NSColor(white: 1, alpha: 0.045))
    static let surfaceBorder = Color(light: NSColor(white: 0, alpha: 0.08),
                                     dark: NSColor(white: 1, alpha: 0.06))

    static func apply(_ preset: AccentPreset) {
        accent = preset.color
    }
}

private extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

/// Named accent colour choices offered in Settings, in the same spirit as
/// macOS's own accent colour picker. `blue` matches the Tauri app's accent
/// exactly (`--accent: #0a84ff`).
enum AccentPreset: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
        case .purple: return Color(red: 0.49, green: 0.42, blue: 0.95)
        case .pink: return Color(red: 1.0, green: 0.18, blue: 0.49)
        case .red: return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .orange: return Color(red: 1.0, green: 0.58, blue: 0.0)
        case .yellow: return Color(red: 1.0, green: 0.80, blue: 0.0)
        case .green: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .graphite: return Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }

    static var `default`: AccentPreset { .blue }
}
