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

@MainActor
enum WindowActivation {
    static func activate(_ window: NSWindow?, showsDockIcon: Bool = true) {
        NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate()
        NSRunningApplication.current.activate(options: activationOptions)
    }

    /// Activating synchronously right after a window is shown or a popover
    /// is dismissed races the window server and the accessory→regular
    /// activation-policy switch (which needs a moment to take effect), and
    /// can leave Forel's menu bar (Forel/File/Edit/View…) not swapped in
    /// even though the window itself comes to the front. Deferring a tick,
    /// then again shortly after, avoids that race — use this instead of
    /// calling `activate` directly from a UI action.
    static func activateSoon(_ window: NSWindow?, showsDockIcon: Bool = true) {
        DispatchQueue.main.async {
            activate(window, showsDockIcon: showsDockIcon)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            activate(window, showsDockIcon: showsDockIcon)
        }
    }

    private static var activationOptions: NSApplication.ActivationOptions {
        // rawValue 1 is the legacy "ignore other apps" bit, kept without
        // referencing the deprecated symbol directly. Deliberately excludes
        // rawValue 2 (`.activateAllWindows`): that flag un-hides *every*
        // window of the app on activation, including ones intentionally
        // ordered out (e.g. the main window while only Settings should be
        // shown) — it was the cause of "Settings" in the quick panel opening
        // the main Forel window instead.
        NSApplication.ActivationOptions(rawValue: 1)
    }
}

struct WindowActivationBridge: NSViewRepresentable {
    let showsDockIcon: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            WindowActivation.activate(view.window, showsDockIcon: showsDockIcon)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            WindowActivation.activate(nsView.window, showsDockIcon: showsDockIcon)
        }
    }
}
