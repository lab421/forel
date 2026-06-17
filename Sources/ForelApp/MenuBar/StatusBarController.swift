import AppKit
import SwiftUI
import Combine
import ForelCore

/// Menu-bar item: Forel glyph with a green/red status dot. Clicking it shows
/// a SwiftUI quick panel (`QuickPanelView`) styled as a dark glass popover,
/// in place of the old plain `NSMenu`.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let updater: UpdaterManager
    private weak var window: NSWindow?
    private var popover: NSPopover?
    private var pausedSubscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?

    init(model: AppModel, updater: UpdaterManager, window: NSWindow?) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.model = model
        self.updater = updater
        self.window = window
        super.init()

        if let button = statusItem.button {
            button.image = Self.glyph(paused: model.paused, updateAvailable: updater.updateAvailable)
            button.image?.isTemplate = false
            button.target = self
            button.action = #selector(togglePopover)
        }

        pausedSubscription = model.$paused.sink { [weak self] paused in
            self?.refreshGlyph(paused: paused)
        }
        updateSubscription = updater.$updateAvailable.sink { [weak self] _ in
            guard let self else { return }
            self.refreshGlyph(paused: self.model.paused)
        }
    }

    private func refreshGlyph(paused: Bool) {
        statusItem.button?.image = Self.glyph(paused: paused, updateAvailable: updater.updateAvailable)
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let panel = QuickPanelView(
            onOpenMainWindow: { [weak self] in
                self?.popover?.performClose(nil)
                self?.openForel()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(model)
        .environmentObject(updater)

        let newPopover = NSPopover()
        newPopover.contentViewController = NSHostingController(rootView: panel)
        newPopover.behavior = .transient
        popover = newPopover

        if let button = statusItem.button {
            newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openForel() {
        let targetWindow = window ?? NSApp.windows.first { !($0 is NSPanel) }
        WindowActivation.activate(targetWindow)
    }

    /// Menu bar glyph: the white Forel leaf, with a colour dot composited in
    /// the bottom-right corner (watching/paused) and, when an update is
    /// available, a larger orange badge with a white ring overlapping the
    /// top-right corner so it reads at a glance. Always white (not
    /// template-tinted), per the app's dark menu-bar styling.
    private static func glyph(paused: Bool, updateAvailable: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let tray = AppIcons.trayGlyph {
            tray.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: size - 4, height: size - 4), xRadius: 3, yRadius: 3).fill()
        }
        image.unlockFocus()

        let dotSize: CGFloat = size / 3
        let dotImage = dot(paused: paused, size: dotSize)
        image.lockFocus()
        dotImage.draw(at: NSPoint(x: size - dotSize - 1, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
        if updateAvailable {
            let badgeSize: CGFloat = size / 2
            let badgeImage = ringedDot(color: .systemOrange, size: badgeSize)
            badgeImage.draw(
                at: NSPoint(x: size - badgeSize * 0.7, y: size - badgeSize * 0.7),
                from: .zero, operation: .sourceOver, fraction: 1
            )
        }
        image.unlockFocus()
        return image
    }

    private static func dot(paused: Bool, size: CGFloat) -> NSImage {
        dot(color: paused ? .systemRed : .systemGreen, size: size)
    }

    private static func dot(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        return image
    }

    /// A filled dot with a white ring around it, so it stays legible against
    /// both light and dark menu bars instead of blending into the glyph.
    private static func ringedDot(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        let inset = size * 0.18
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)).fill()
        image.unlockFocus()
        return image
    }
}
