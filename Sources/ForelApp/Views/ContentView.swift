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

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 270, max: 320)
                .modifier(SidebarToggleRemovalModifier())
        } detail: {
            switch model.detailRoute {
            case .rules:
                RuleListView()
            case .history:
                HistoryView()
            }
        }
        .toolbarBackground(ForelTheme.background, for: .windowToolbar)
        .alert(model.alertTitle, isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .tint(ForelTheme.accent)
        // ForelTheme.accent is a plain static var, not observable; bumping the
        // identity here forces every descendant to rebuild and re-read it.
        .id(model.accentVersion)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: {
                if !$0 {
                    model.errorMessage = nil
                    model.alertTitle = "Error"
                }
            }
        )
    }
}

/// `.toolbar(removing: .sidebarToggle)` requires macOS 14+; there's no
/// equivalent way to remove the default sidebar toggle on macOS 13.
private struct SidebarToggleRemovalModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}
