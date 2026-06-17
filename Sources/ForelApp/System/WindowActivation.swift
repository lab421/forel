import AppKit
import SwiftUI

@MainActor
enum WindowActivation {
    static func activate(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate()
        NSRunningApplication.current.activate(options: activationOptions)
    }

    private static var activationOptions: NSApplication.ActivationOptions {
        // rawValue keeps compatibility with the legacy "ignore other apps"
        // bit without referencing the deprecated symbol directly.
        NSApplication.ActivationOptions(rawValue: 1 | 2)
    }
}

struct WindowActivationBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            WindowActivation.activate(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            WindowActivation.activate(nsView.window)
        }
    }
}
