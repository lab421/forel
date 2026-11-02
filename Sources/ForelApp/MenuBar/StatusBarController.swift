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
import SwiftUI
import Combine
import ForelCore
import Lab421Licensing

/// Menu-bar item: Forel's leaf glyph, tinted by macOS. Clicking it shows
/// a SwiftUI quick panel (`QuickPanelView`) styled as a dark glass popover,
/// in place of the old plain `NSMenu`.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let updater: UpdaterManager
    private let license: ForelLicenseManager
    private let onOpenMainWindow: () -> Void
    private var popover: NSPopover?
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?
    private var pausedSubscription: AnyCancellable?
    private var updateSubscription: AnyCancellable?
    private var licenseSubscription: AnyCancellable?
    private var onOpenLicense: (() -> Void)?

    init(model: AppModel, updater: UpdaterManager, license: ForelLicenseManager, onOpenMainWindow: @escaping () -> Void, onOpenLicense: (() -> Void)? = nil) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.model = model
        self.updater = updater
        self.license = license
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenLicense = onOpenLicense
        super.init()

        if let button = statusItem.button {
            button.image = Self.glyph(paused: model.paused, updateAvailable: updater.updateAvailable)
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
        licenseSubscription = license.$state.sink { [weak self] _ in
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

        var panel = QuickPanelView(
            onOpenMainWindow: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenMainWindow()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        panel.onOpenLicense = { [weak self] in
            self?.popover?.performClose(nil)
            self?.onOpenLicense?()
        }

        let hostingController = NSHostingController(
            rootView: panel
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(license)
        )

        let newPopover = NSPopover()
        newPopover.contentViewController = hostingController
        newPopover.behavior = .transient
        newPopover.delegate = self
        popover = newPopover

        if let button = statusItem.button {
            newPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startDismissEventMonitors()
        }
    }

    private func startDismissEventMonitors() {
        stopDismissEventMonitors()

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closePopoverIfClickIsOutside(event)
            return event
        }

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }
    }

    private func stopDismissEventMonitors() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
    }

    private func closePopoverIfClickIsOutside(_ event: NSEvent) {
        guard let popover, popover.isShown else { return }
        if event.window == popover.contentViewController?.view.window { return }
        if let button = statusItem.button, event.window == button.window {
            let point = button.convert(event.locationInWindow, from: nil)
            if button.bounds.contains(point) { return }
        }
        closePopover()
    }

    private func closePopover() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Menu bar glyph, drawn as a template image (black and clear) so macOS
    /// tints it like every other menu bar icon, in light and dark mode. The
    /// state shows in the shape, never in color: a filled leaf while
    /// watching, an outlined leaf when paused, and a small dot in the
    /// top-right corner when an update is available.
    private static func glyph(paused: Bool, updateAvailable: Bool, size: CGFloat = 18) -> NSImage {
        // Smaller than its box to match the visual weight of the system
        // menu bar glyphs around it.
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.78, weight: .regular)
        let symbol = NSImage(systemSymbolName: paused ? "leaf" : "leaf.fill", accessibilityDescription: "Forel")?
            .withSymbolConfiguration(config)

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let symbol {
            let drawSize = symbol.size
            symbol.draw(in: NSRect(
                x: (size - drawSize.width) / 2,
                y: (size - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
        } else {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: size - 4, height: size - 4), xRadius: 3, yRadius: 3).fill()
        }
        if updateAvailable {
            let dotSize = size / 3
            let dot = NSRect(x: size - dotSize, y: size - dotSize, width: dotSize, height: dotSize)
            // Clear a thin gap around the dot so it stays apart from the leaf.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        stopDismissEventMonitors()
    }
}
