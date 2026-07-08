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

import SwiftUI
import ForelCore

@main
struct ForelMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var updater: UpdaterManager

    init() {
        let model = try! AppModel()
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: UpdaterManager(db: model.db))
    }

    var body: some Scene {
        WindowGroup("Forel") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 960, minHeight: 520)
                .onAppear {
                    appDelegate.configure(model: model, updater: updater)
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Forel") {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "alpha"
                    let icon = Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Forel",
                        .applicationVersion: version,
                        .applicationIcon: icon as Any,
                    ])
                }
            }
        }

        // A real `Settings` scene (not an in-app route) so Settings behaves
        // like every other macOS app: its own window, a "Settings…" item
        // under the Forel menu, and the standard ⌘, shortcut, all wired up
        // automatically by SwiftUI.
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
        .windowResizability(.contentSize)
    }
}
