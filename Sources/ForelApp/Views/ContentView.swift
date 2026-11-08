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
                    Button("Discover Pro") { model.proUpgrade = .folders }
                        .buttonStyle(.link)
                        .padding(16)
                }
            }
        }
        .toolbarBackground(ForelTheme.background, for: .windowToolbar)
        .alert(model.alertTitle, isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .tint(ForelTheme.accent)
        .confirmationDialog(unsavedRuleTitle, isPresented: pendingNavigationBinding, presenting: model.pendingNavigation) { _ in
            if unsavedRuleProblems.isEmpty {
                Button("Save") { model.savePendingDraftAndNavigate() }
            }
            Button("Discard Changes", role: .destructive) { model.discardPendingDraftAndNavigate() }
            Button("Keep Editing", role: .cancel) { model.pendingNavigation = nil }
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
        return name.isEmpty ? "Save changes to this rule?" : "Save changes to the rule “\(name)”?"
    }

    private var unsavedRuleMessage: String {
        if let problem = unsavedRuleProblems.first {
            return "It can't be saved yet: \(problem) Keep editing to fix it, or discard your changes."
        }
        return "Your changes to this rule are lost if you don't save them."
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
