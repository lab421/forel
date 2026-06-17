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
    private weak var window: NSWindow?
    private let checkForUpdates: () -> Void
    private var popover: NSPopover?
    private var pausedSubscription: AnyCancellable?

    init(model: AppModel, window: NSWindow?, checkForUpdates: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.model = model
        self.window = window
        self.checkForUpdates = checkForUpdates
        super.init()

        if let button = statusItem.button {
            button.image = Self.glyph(paused: model.paused)
            button.image?.isTemplate = false
            button.target = self
            button.action = #selector(togglePopover)
        }

        pausedSubscription = model.$paused.sink { [weak self] paused in
            self?.statusItem.button?.image = Self.glyph(paused: paused)
        }
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
            onCheckForUpdates: { [weak self] in
                self?.popover?.performClose(nil)
                self?.openForel()
                self?.checkForUpdates()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        .environmentObject(model)

        let newPopover = NSPopover()
        newPopover.contentViewController = NSHostingController(rootView: panel)
        newPopover.behavior = .transient
        popover = newPopover

        if let button = statusItem.button {
            newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openForel() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Menu bar glyph with a colour dot composited in the bottom-right corner.
    private static func glyph(paused: Bool, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.labelColor.setFill()
        let bodyRect = NSRect(x: 2, y: 2, width: size - 4, height: size - 4)
        NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3).fill()
        image.unlockFocus()

        let dotSize: CGFloat = size / 3
        let dotImage = dot(paused: paused, size: dotSize)
        image.lockFocus()
        dotImage.draw(at: NSPoint(x: size - dotSize - 1, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }

    private static func dot(paused: Bool, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        (paused ? NSColor.systemRed : NSColor.systemGreen).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        image.unlockFocus()
        return image
    }
}
