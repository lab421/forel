import SwiftUI

/// Dark "glass" palette for the menu-bar quick panel, inspired by Vorssaint's
/// popover style: near-black translucent background, indigo accent, soft
/// white-opacity surfaces instead of hard borders.
enum ForelTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.10)
    static let accent = Color(red: 0.49, green: 0.42, blue: 0.95)
    static let success = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let danger = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.55)
    static let divider = Color.white.opacity(0.08)
    static let surface = Color.white.opacity(0.045)
    static let surfaceBorder = Color.white.opacity(0.06)
}
