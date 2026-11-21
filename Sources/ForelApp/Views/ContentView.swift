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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 280, max: 320)
                // Replaced by a toggle that shows whether the sidebar is open.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                if let rule = model.editingRule {
                    RuleEditorView(rule: rule) { saved in
                        if model.saveRule(saved) { model.closeRuleEditor() }
                    } onCancel: {
                        model.closeRuleEditor()
                    }
                    .id(rule.id)
                } else {
                    switch model.detailRoute {
                    case .rules:
                        RuleListView()
                    case .history:
                        HistoryView()
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !model.isPro, model.editingRule == nil {
                    Button(L10n.string("discover_pro")) { model.proUpgrade = .folders }
                        .buttonStyle(.link)
                        .padding(16)
                }
            }
            // One toggle, always at the start of the window's own title bar:
            // beside the sidebar when shown, beside the window controls when not.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    SidebarToggle(visibility: $columnVisibility)
                }
                .withoutSharedBackground()
            }
        }
        .alert(model.alertTitle, isPresented: errorBinding) {
            Button(L10n.string("window_ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .tint(ForelTheme.accent)
        .confirmationDialog(unsavedRuleTitle, isPresented: pendingNavigationBinding, presenting: model.pendingNavigation) { _ in
            if unsavedRuleProblems.isEmpty {
                Button(L10n.string("save")) { model.savePendingDraftAndNavigate() }
            }
            Button(L10n.string("window_discard_changes"), role: .destructive) { model.discardPendingDraftAndNavigate() }
            Button(L10n.string("window_keep_editing"), role: .cancel) { model.pendingNavigation = nil }
        } message: { _ in
            Text(unsavedRuleMessage)
        }
        .sheet(item: $model.proUpgrade) { context in
            ProUpgradeView(context: context)
        }
        // ForelTheme.accent is a plain static var, not observable; bumping the
        // identity here forces every descendant to rebuild and re-read it.
        .id(model.accentVersion)
    }

    private var pendingNavigationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingNavigation != nil },
            set: { if !$0 { model.pendingNavigation = nil } }
        )
    }

    private var unsavedRuleProblems: [String] {
        model.editingDraft.map(RuleEditorDraftCheck.problems) ?? []
    }

    private var unsavedRuleTitle: String {
        let name = model.editingDraft?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty
            ? L10n.string("window_save_changes_rule")
            : L10n.string("window_save_changes_to_the_rule", name)
    }

    private var unsavedRuleMessage: String {
        if let problem = unsavedRuleProblems.first {
            return L10n.string("window_cant_saved_yet_keep", problem)
        }
        return L10n.string("window_changes_rule_lost_if")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: {
                if !$0 {
                    model.errorMessage = nil
                    model.alertTitle = L10n.string("error")
                }
            }
        )
    }
}

/// Plain title bar button that hides or shows the sidebar.
private struct SidebarToggle: View {
    @Binding var visibility: NavigationSplitViewVisibility

    var body: some View {
        let isShown = visibility != .detailOnly
        Button {
            withAnimation { visibility = isShown ? .detailOnly : .all }
        } label: {
            Image(systemName: "sidebar.left")
                .foregroundStyle(ForelTheme.secondaryText)
        }
        .buttonStyle(.borderless)
        .help(isShown ? L10n.string("window_hide_sidebar") : L10n.string("window_show_sidebar"))
        .accessibilityLabel(isShown ? L10n.string("window_hide_sidebar") : L10n.string("window_show_sidebar"))
    }
}

private extension ToolbarContent {
    /// Drops the glass capsule macOS 26 draws around toolbar items.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
