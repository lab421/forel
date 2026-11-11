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
import AppKit
import ForelCore

struct RuleListView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedRuleIDs: Set<String> = []
    @State private var copyRequest: RuleCopyRequest?

    private var selectedFolder: WatchedFolder? {
        model.folders.first { $0.id == model.selectedFolderId }
    }

    var body: some View {
        content
            .sheet(item: $model.previewResult) { result in
                PreviewSheet(result: result) { model.previewResult = nil }
            }
            .sheet(item: $copyRequest) { request in
                CopyRulesSheet(
                    ruleCount: request.ruleIDs.count,
                    sourceFolderID: request.sourceFolderID,
                    folders: model.folders, isPro: model.isPro,
                    onCopy: { destination in
                        try model.copyRules(request.ruleIDs, fromFolderID: request.sourceFolderID, toFolderID: destination)
                        copyRequest = nil
                    },
                    onCancel: { copyRequest = nil }
                )
            }
            .onChange(of: model.selectedFolderId) { _, _ in selectedRuleIDs.removeAll() }
            .onChange(of: model.rules.map(\.id)) { _, ids in selectedRuleIDs.formIntersection(ids) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let notice = model.planNotice {
                HStack {
                    Text(notice)
                    .font(.caption)
                    .foregroundStyle(ForelTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Discover Pro") {
                        model.proUpgrade = model.selectedFolderIsAllowed ? .monthlyFiles : .folders
                    }
                        .buttonStyle(.link)
                }
            }
            if model.paused, model.selectedFolderId != nil {
                pausedBanner
            }
            if !model.rules.isEmpty {
                actionBar
            }
            if !selectedRuleIDs.isEmpty {
                HStack {
                    Text("\(selectedRuleIDs.count) rules selected")
                        .font(.caption)
                        .foregroundStyle(ForelTheme.secondaryText)
                    Button("Copy rules to folder…") { requestCopy(selectedRuleIDs) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Deselect all") { selectedRuleIDs.removeAll() }
                        .buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            }

            if let runNowMessage = model.runNowMessageForSelectedFolder {
                runNowBanner(runNowMessage)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.rules.isEmpty {
                VStack {
                    Spacer(minLength: 0)
                    emptyState
                    Spacer(minLength: 0)
                }
            } else {
                List(selection: $selectedRuleIDs) {
                    ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                        VStack(alignment: .leading, spacing: 4) {
                            if !model.selectedFolderIsAllowed || (!model.isPro && FreePlan.requiredFeature(for: rule) != nil) {
                                Button("Kept for Pro — not running") {
                                    if let feature = FreePlan.requiredFeature(for: rule) {
                                        model.proUpgrade = .feature(feature)
                                    } else {
                                        model.proUpgrade = .folders
                                    }
                                }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    .foregroundStyle(ForelTheme.secondaryText)
                            }
                            if !rule.isSupported {
                                Label("Created with a newer version of Forel — not running. Update Forel to run or edit it.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(ForelTheme.secondaryText)
                            }
                            RuleCard(
                            rule: rule,
                            order: index + 1,
                            isExpanded: model.isRuleExpanded(rule),
                            isSelected: selectedRuleIDs.contains(rule.id),
                            onToggleExpanded: { model.toggleRuleExpanded(rule) },
                            onEdit: { model.editingRule = rule },
                            onCopy: { requestCopy([rule.id]) }
                            )
                        }
                            .tag(rule.id)
                            .background(RuleListSelectionAppearance())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove(perform: moveRules)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Copy rules to folder…") { requestCopy(ids) }
                        .disabled(ids.isEmpty)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.runNowMessageForSelectedFolder)
        .padding(16)
        .frame(minWidth: 460)
        .background(ForelTheme.background)
    }

    private func requestCopy(_ ruleIDs: Set<String>) {
        guard let sourceFolderID = model.selectedFolderId, !ruleIDs.isEmpty else { return }
        copyRequest = RuleCopyRequest(sourceFolderID: sourceFolderID, ruleIDs: ruleIDs)
    }

    private func moveRules(from source: IndexSet, to destination: Int) {
        var ids = model.rules.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.reorderRules(ids)
    }

    @ViewBuilder
    private func runNowBanner(_ message: AppModel.RunNowMessage) -> some View {
        let tint = message.hasFailures ? Color.orange : ForelTheme.success
        HStack(spacing: 6) {
            Image(systemName: message.hasFailures ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(message.text)
            if message.hasFailures {
                Button {
                    model.dismissRunNowMessage()
                    model.showActivity(forFolder: message.folderId)
                } label: {
                    Text("Show in Activity").underline()
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                Button {
                    model.dismissRunNowMessage()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var header: some View {
        ViewHeader(
            title: selectedFolder.map { Text(verbatim: ($0.path as NSString).lastPathComponent) } ?? Text("Rules"),
            subtitle: model.selectedFolderId == nil
                ? Text("Select a folder to manage its rules")
                : Text("\(model.rules.count) rules · drag to reorder"),
            systemImage: selectedFolder == nil ? nil : "folder.fill"
        ) {
            Button {
                model.showActivity()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(IconButtonStyle())
            .help("Activity history")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                guard let folderId = model.selectedFolderId else { return }
                guard model.canAddRule else {
                    model.proUpgrade = .folders
                    return
                }
                model.editingRule = Rule(folderId: folderId, name: String(localized: "New Rule", comment: "Default name of a new rule"))
            } label: {
                Label("New Rule", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canAddRule)
            .opacity(model.canAddRule ? 1 : 0.45)

            Button {
                model.runNow()
            } label: {
                if model.isRunningNow {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running…")
                    }
                } else {
                    Label("Run Now", systemImage: "play.fill")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!model.selectedFolderIsAllowed || model.isRunningNow)
            .opacity(model.selectedFolderIsAllowed ? 1 : 0.45)

            Button {
                model.preview()
            } label: {
                if model.isPreviewing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                    }
                } else {
                    Label("Preview (Dry Run)", systemImage: "eye")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!model.selectedFolderIsAllowed || model.isPreviewing)
            .opacity(model.selectedFolderIsAllowed ? 1 : 0.45)

            Spacer()
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("Automatic watching is paused")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ForelTheme.primaryText)
                Text("Rules only run when you choose Run Now.")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
            }

            Spacer(minLength: 8)

            Button("Resume Watching", action: model.togglePaused)
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.selectedFolderId == nil {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 28))
                    .foregroundStyle(ForelTheme.secondaryText)
                Text("No folder selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                Text("Pick a folder on the left to see its rules.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 28))
                    .foregroundStyle(ForelTheme.secondaryText)
                Text("No rules yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                Text(model.canAddRule
                     ? "Create a rule to automate files in this folder."
                     : "Reorder folders or activate Pro to add rules in this folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .multilineTextAlignment(.center)
                Button {
                    guard let folderId = model.selectedFolderId else { return }
                    guard model.canAddRule else {
                        model.proUpgrade = .folders
                        return
                    }
                    model.editingRule = Rule(folderId: folderId, name: String(localized: "New Rule", comment: "Default name of a new rule"))
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 8)
                .disabled(!model.canAddRule)
                .opacity(model.canAddRule ? 1 : 0.45)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

private struct RuleCard: View {
    @EnvironmentObject var model: AppModel
    let rule: Rule
    let order: Int
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpanded: () -> Void
    let onEdit: () -> Void
    let onCopy: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText.opacity(0.6))
                    .frame(width: 18, height: 24)
                    .pointingHandCursor()

                Button(action: onToggleExpanded) {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ForelTheme.secondaryText.opacity(0.75))
                            .frame(width: 12)

                        ZStack {
                            Circle().fill(ForelTheme.accent.opacity(0.16))
                            Text("\(order)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(ForelTheme.accent)
                        }
                        .frame(width: 22, height: 22)
                    }
                    .frame(width: 54, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(ForelTheme.accent)
                    .controlSize(.small)
                    .disabled(!model.selectedFolderIsAllowed)

                Button(action: onToggleExpanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ForelTheme.primaryText)
                        HStack(spacing: 6) {
                            metaPill(icon: "line.3.horizontal.decrease.circle", text: "\(rule.conditions.count)")
                            metaPill(icon: "bolt.fill", text: "\(rule.actions.count)")
                            if let stats = model.runStats(for: rule) {
                                let totalRuns = stats.successCount + stats.failedCount
                                if totalRuns > 0 {
                                    Text("\(totalRuns) runs (30d)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(ForelTheme.secondaryText)
                                        .help("Last 30 days: \(stats.successCount) successful, \(stats.failedCount) failed")
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Spacer(minLength: 8)

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!rule.isSupported)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!rule.isSupported)

                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(IconButtonStyle(role: .destructive))
                .help("Delete this rule…")
                .accessibilityLabel("Delete rule")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)

            if isExpanded {
                Divider()
                    .overlay(ForelTheme.divider)
                    .padding(.horizontal, 12)
                Group {
                    if rule.isSupported {
                        RuleDetails(rule: rule)
                    } else {
                        // This version would show its guess for what it
                        // doesn't know, which would be wrong.
                        Text("This version of Forel can't show this rule's details.")
                            .font(.system(size: 12))
                            .foregroundStyle(ForelTheme.secondaryText)
                    }
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? ForelTheme.accent : (isExpanded ? ForelTheme.accent.opacity(0.55) : ForelTheme.surfaceBorder),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .opacity(rule.enabled && rule.isSupported && model.selectedFolderIsAllowed ? 1 : 0.6)
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete) {
            Button("Delete Rule", role: .destructive) { model.deleteRule(rule) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteTitle: String {
        let name = rule.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty
            ? String(localized: "Delete this rule?")
            : String(localized: "Delete the rule “\(name)”?")
    }

    /// Says what goes and what stays, so the choice is informed.
    private var deleteMessage: String {
        String(localized: "Its \(rule.conditions.count) conditions and \(rule.actions.count) actions are deleted, and this can't be undone. Files it already processed stay where they are, and its past activity is kept.")
    }

    private func metaPill(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(ForelTheme.secondaryText)
    }


    private var enabledBinding: Binding<Bool> {
        Binding(get: { rule.enabled && model.selectedFolderIsAllowed }, set: { model.toggleRule(rule, enabled: $0) })
    }
}

/// Keep native List selection and keyboard handling without drawing a second,
/// rectangular selection background behind the rounded rule cards.
private struct RuleListSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionAppearanceView { SelectionAppearanceView() }

    func updateNSView(_ view: SelectionAppearanceView, context: Context) {
        view.removeNativeHighlight()
    }

    final class SelectionAppearanceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeNativeHighlight()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            removeNativeHighlight()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func removeNativeHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct RuleCopyRequest: Identifiable {
    let id = UUID()
    let sourceFolderID: String
    let ruleIDs: Set<String>
}

private struct RuleDetails: View {
    let rule: Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailSection(
                label: "IF",
                rows: conditionRows,
                emptyText: "Matches every file in scope."
            )

            detailSection(
                label: "DO",
                rows: actionRows,
                emptyText: "No actions configured."
            )
        }
        .textSelection(.enabled)
    }

    private var conditionRows: [RuleDetailRow] {
        rule.conditions.map { condition in
            RuleDetailRow(
                icon: condition.kind.iconSystemName,
                badge: condition.kind.label,
                title: "\(condition.operator.label) \(condition.value)",
                detail: nil
            )
        }
    }

    private var actionRows: [RuleDetailRow] {
        rule.actions.sorted { $0.position < $1.position }.map { action in
            let summary = actionSummary(action)
            return RuleDetailRow(
                icon: action.kind.iconSystemName,
                badge: action.kind.label,
                title: summary.title,
                detail: summary.detail
            )
        }
    }

    private func detailSection(label: LocalizedStringKey, rows: [RuleDetailRow], emptyText: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(width: 22, alignment: .trailing)
                .padding(.top, rows.isEmpty ? 1 : 6)

            VStack(alignment: .leading, spacing: 6) {
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .frame(minHeight: 24, alignment: .center)
                } else {
                    ForEach(rows) { row in
                        ruleDetailRow(row)
                    }
                }
            }
        }
    }

    private func ruleDetailRow(_ row: RuleDetailRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: row.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ForelTheme.accent)
                .frame(width: 14)

            Text(row.badge)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(ForelTheme.accent)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(ForelTheme.accent.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(ForelTheme.accent.opacity(0.25))
                )

            Text(row.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ForelTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            if let detail = row.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func actionSummary(_ action: Action) -> (title: String, detail: String?) {
        switch action.kind {
        case .moveToFolder:
            return (String(localized: "to folder", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), action.params[ActionParam.destination]?.stringValue)
        case .copyToFolder:
            return (String(localized: "to folder", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), action.params[ActionParam.destination]?.stringValue)
        case .syncFolders:
            return (String(localized: "with folder", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), action.params[ActionParam.destination]?.stringValue)
        case .rename:
            let pattern = action.params[ActionParam.pattern]?.stringValue ?? ""
            return (String(localized: "to \(pattern)", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), action.params[ActionParam.cleanFileName]?.boolValue == true ? String(localized: "clean file name", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : nil)
        case .moveToTrash:
            return (String(localized: "move to Trash", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), nil)
        case .delete:
            return (String(localized: "delete permanently", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), nil)
        case .addTag:
            return (String(localized: "add \(tagList(action))", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), nil)
        case .removeTag:
            return (String(localized: "remove \(tagList(action))", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), nil)
        case .setColorLabel:
            let color = action.params[ActionParam.color]?.stringValue ?? ""
            return (color.isEmpty ? String(localized: "clear color label", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : String(localized: "set to \(FinderTags.displayName(forColor: color))", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), nil)
        case .toggleLock:
            return (action.params[ActionParam.locked]?.boolValue == true ? String(localized: "lock", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : String(localized: "unlock", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), nil)
        case .toggleExtension:
            return (action.params[ActionParam.extensionHidden]?.boolValue == true ? String(localized: "hide extension", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : String(localized: "show extension", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), nil)
        case .runScript:
            let script = action.params[ActionParam.script]?.stringValue ?? ""
            let lines = script.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let firstLine = lines.first.map(String.init) ?? ""
            return (firstLine.isEmpty ? String(localized: "run script", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : firstLine, lines.count > 1 ? String(localized: "\(lines.count) lines", comment: "Length of a script") : nil)
        case .runShortcut:
            let name = action.params[ActionParam.shortcutName]?.stringValue ?? ""
            return (name.isEmpty ? String(localized: "run shortcut", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : name, ActionExecutor.shortcutInputMode(action).label)
        case .openApplication:
            let path = action.params[ActionParam.applicationPath]?.stringValue ?? ""
            let appName = path.isEmpty ? String(localized: "open application", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let detail = ActionExecutor.passesFileToApplication(action) ? String(localized: "with matched file", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") : nil
            return (appName, detail)
        case .importToLibrary:
            let library = LibraryType(rawValue: action.params[ActionParam.libraryType]?.stringValue ?? "")
            let playlist = action.params[ActionParam.targetPlaylist]?.stringValue ?? ""
            let title = library.map { String(localized: "import to \($0.label)", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)") } ?? String(localized: "import to library", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)")
            return (title, playlist.isEmpty ? nil : playlist)
        case .uncompress:
            return (String(localized: "uncompress ZIP", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), MoveConflictResolution(rawValue: action.params[ActionParam.onConflict]?.stringValue ?? "")?.label)
        case .compress:
            let name = action.params[ActionParam.archiveName]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let destination = action.params[ActionParam.destination]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var details = [name.isEmpty ? "{name}.zip" : name]
            if !destination.isEmpty { details.append(String(localized: "to \(destination)", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)")) }
            if ActionExecutor.deletesSourceAfterCompression(action) { details.append(String(localized: "permanently delete source after success", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)")) }
            return (String(localized: "create ZIP", comment: "Rule summary in the rule list, after the action name (as in “RENAME to …”)"), details.joined(separator: " · "))
        }
    }

    private func tagList(_ action: Action) -> String {
        if let tags = action.params[ActionParam.tags]?.arrayValue?.compactMap(\.stringValue), !tags.isEmpty {
            return tags.joined(separator: ", ")
        }
        if let tag = action.params["tag"]?.stringValue, !tag.isEmpty {
            return tag
        }
        return String(localized: "tag", comment: "Rule summary for an Add or Remove Tag action without tags, as in “add tag”")
    }
}

private struct RuleDetailRow: Identifiable {
    let id = UUID()
    let icon: String
    let badge: String
    let title: String
    let detail: String?
}

private extension View {
    func pointingHandCursor() -> some View {
        onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension PreviewResult: Identifiable {
    public var id: Int { filesScanned.hashValue ^ matches.count.hashValue ^ reachedMatchLimit.hashValue }
}

extension Rule: Identifiable {}

private struct PreviewSheet: View {
    let result: PreviewResult
    let onClose: () -> Void

    private var subtitle: String {
        let matchText = result.reachedMatchLimit
            ? String(localized: "\(result.matches.count)+ matched", comment: "Dry Run: more files matched than shown")
            : String(localized: "\(result.matches.count) matched", comment: "Dry Run: number of matching files")
        return String(localized: "\(result.filesScanned) items scanned · \(matchText)", comment: "Dry Run summary; %@ is the number matched")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: Text("Preview (Dry Run)"),
                subtitle: Text(subtitle)
            )

            ScrollView {
                LazyVStack(spacing: 8) {
                    if result.reachedMatchLimit, let matchLimit = result.matchLimit {
                        HStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ForelTheme.accent)
                            Text("Showing the first \(matchLimit) matches. Narrow the folder scope or conditions to see fewer results.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(ForelTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.accent.opacity(0.10)))
                    }

                    ForEach(result.matches, id: \.path) { match in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.fill").font(.system(size: 11)).foregroundStyle(ForelTheme.accent)
                                Text(match.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                            }
                            Text(match.path)
                                .font(.system(size: 10))
                                .foregroundStyle(ForelTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                            ForEach(match.rules, id: \.ruleId) { rulePreview in
                                Text(rulePreview.ruleName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ForelTheme.secondaryText)
                                ForEach(Array(rulePreview.conditions.enumerated()), id: \.offset) { _, condition in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: condition.matched ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(condition.matched ? ForelTheme.accent : .red.opacity(0.85))
                                            Text(condition.label)
                                                .font(.system(size: 11))
                                                .foregroundStyle(ForelTheme.secondaryText)
                                                .lineLimit(1)
                                        }
                                        if let detail = condition.detail {
                                            Text(detail)
                                                .font(.system(size: 10))
                                                .foregroundStyle(ForelTheme.secondaryText)
                                                .lineLimit(1)
                                                .padding(.leading, 15)
                                        }
                                    }
                                    .padding(.leading, 6)
                                }
                                if rulePreview.actions.isEmpty {
                                    HStack(spacing: 6) {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 9))
                                            .foregroundStyle(ForelTheme.secondaryText)
                                        Text("No actions configured for this rule.")
                                            .font(.system(size: 11))
                                            .foregroundStyle(ForelTheme.secondaryText)
                                    }
                                    .padding(.leading, 6)
                                } else {
                                    ForEach(rulePreview.actions, id: \.self) { action in
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Image(systemName: action.statusIcon)
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(action.statusColor)
                                                Text(action.description)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(ForelTheme.primaryText)
                                                Text(action.statusLabel)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(action.statusColor)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(action.statusColor.opacity(0.12)))
                                            }
                                            if let targetPath = action.targetPath {
                                                Text("\((action.sourcePath as NSString).lastPathComponent) -> \((targetPath as NSString).lastPathComponent)")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(ForelTheme.secondaryText)
                                            }
                                            if let warning = action.warning {
                                                Text(warning)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.orange)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(.leading, 6)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
                    }

                    if result.matches.isEmpty {
                        Text("No files match the current rules.")
                            .font(.system(size: 12))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
            }
            .textSelection(.enabled)
            .scrollIndicators(.never)

            HStack {
                Spacer()
                Button("Close", action: onClose).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 860, height: 680)
        .background(ForelTheme.background)
    }
}

private extension ConditionPreview {
    var label: String {
        "\(kind.label) \(`operator_`.label) \(value)"
    }
}

private extension ActionPreview {
    var statusLabel: String {
        if warning != nil { return String(localized: "Likely to fail", comment: "Dry Run status of an action") }
        switch status {
        case .wouldRun: return String(localized: "Would run", comment: "Dry Run status of an action")
        case .wouldSkip: return String(localized: "Would skip", comment: "Dry Run status of an action")
        case .blockedByConflict: return String(localized: "Blocked by conflict", comment: "Dry Run status of an action")
        case .needsConfirmation: return String(localized: "Needs confirmation", comment: "Dry Run status of an action")
        }
    }

    var statusIcon: String {
        if warning != nil { return "exclamationmark.triangle.fill" }
        switch status {
        case .wouldRun: return "arrow.turn.down.right"
        case .wouldSkip: return "minus.circle"
        case .blockedByConflict: return "exclamationmark.triangle.fill"
        case .needsConfirmation: return "questionmark.circle.fill"
        }
    }

    @MainActor var statusColor: Color {
        if warning != nil { return .orange }
        switch status {
        case .wouldRun: return ForelTheme.accent
        case .wouldSkip: return ForelTheme.secondaryText
        case .blockedByConflict: return .orange
        case .needsConfirmation: return .purple
        }
    }
}
