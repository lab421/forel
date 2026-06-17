import SwiftUI
import ForelCore

struct RuleListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingRule: Rule?
    @State private var previewResult: PreviewResult?

    private var selectedFolder: WatchedFolder? {
        model.folders.first { $0.id == model.selectedFolderId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actionBar

            if model.rules.isEmpty {
                VStack {
                    Spacer(minLength: 0)
                    emptyState
                    Spacer(minLength: 0)
                }
            } else {
                List {
                    ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                        RuleCard(rule: rule, order: index + 1, onEdit: { editingRule = rule })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove(perform: moveRules)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
            }
        }
        .padding(16)
        .frame(minWidth: 460)
        .background(ForelTheme.background)
        .sheet(item: $editingRule) { rule in
            RuleEditorView(rule: rule) { saved in
                model.saveRule(saved)
                editingRule = nil
            } onCancel: {
                editingRule = nil
            }
        }
        .sheet(item: $previewResult) { result in
            PreviewSheet(result: result) { previewResult = nil }
        }
    }

    private func moveRules(from source: IndexSet, to destination: Int) {
        var ids = model.rules.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.reorderRules(ids)
    }

    private var header: some View {
        ViewHeader(
            title: selectedFolder.map { ($0.path as NSString).lastPathComponent } ?? "Rules",
            subtitle: model.selectedFolderId == nil
                ? "Select a folder to manage its rules"
                : "\(model.rules.count) rule\(model.rules.count == 1 ? "" : "s") · drag to reorder",
            systemImage: selectedFolder == nil ? nil : "folder.fill"
        ) {
            Button {
                model.reloadHistory()
                model.detailRoute = .history
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
                editingRule = Rule(folderId: folderId, name: "New Rule")
            } label: {
                Label("New Rule", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.selectedFolderId == nil)

            Button {
                model.runNow()
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.selectedFolderId == nil)

            Button {
                previewResult = model.preview()
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.selectedFolderId == nil)

            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.selectedFolderId == nil ? "sidebar.left" : "list.bullet.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(ForelTheme.secondaryText)
            Text(model.selectedFolderId == nil ? "No folder selected" : "No rules yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ForelTheme.primaryText)
            Text(model.selectedFolderId == nil
                 ? "Pick a folder on the left to see its rules."
                 : "Create a rule to automate files in this folder.")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

private struct RuleCard: View {
    @EnvironmentObject var model: AppModel
    let rule: Rule
    let order: Int
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText.opacity(0.6))
                ZStack {
                    Circle().fill(ForelTheme.accent.opacity(0.16))
                    Text("\(order)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ForelTheme.accent)
                }
                .frame(width: 22, height: 22)
            }

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(ForelTheme.accent)
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ForelTheme.primaryText)
                HStack(spacing: 6) {
                    metaPill(icon: "line.3.horizontal.decrease.circle", text: "\(rule.conditions.count)")
                    metaPill(icon: "bolt.fill", text: "\(rule.actions.count)")
                    Text(rule.conditionMatch == .all ? "match all" : "match any")
                        .font(.system(size: 10))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
            }

            Spacer(minLength: 8)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(IconButtonStyle())

            Button(role: .destructive) {
                model.deleteRule(rule)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(role: .destructive))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
        .opacity(rule.enabled ? 1 : 0.6)
    }

    private func metaPill(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(ForelTheme.secondaryText)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { rule.enabled }, set: { model.toggleRule(rule, enabled: $0) })
    }
}

extension PreviewResult: Identifiable {
    public var id: Int { filesScanned.hashValue ^ matches.count.hashValue }
}

extension Rule: Identifiable {}

private struct PreviewSheet: View {
    let result: PreviewResult
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Preview",
                subtitle: "\(result.filesScanned) scanned · \(result.matches.count) would change"
            )

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(result.matches, id: \.path) { match in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.fill").font(.system(size: 11)).foregroundStyle(ForelTheme.accent)
                                Text(match.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                            }
                            ForEach(match.rules, id: \.ruleId) { rulePreview in
                                Text(rulePreview.ruleName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ForelTheme.secondaryText)
                                ForEach(rulePreview.actions, id: \.self) { action in
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(ForelTheme.secondaryText)
                                        Text(action).font(.system(size: 11)).foregroundStyle(ForelTheme.primaryText)
                                    }
                                    .padding(.leading, 6)
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
            .scrollIndicators(.never)

            HStack {
                Spacer()
                Button("Close", action: onClose).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 480, height: 460)
        .background(ForelTheme.background)
    }
}
