import SwiftUI
import ForelCore

struct RuleListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingRule: Rule?

    private var selectedFolder: WatchedFolder? {
        model.folders.first { $0.id == model.selectedFolderId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actionBar

            if let runNowMessage = model.runNowMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(runNowMessage)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ForelTheme.success)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(ForelTheme.success.opacity(0.14)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
        .animation(.easeInOut(duration: 0.25), value: model.runNowMessage)
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
        .sheet(item: $model.previewResult) { result in
            PreviewSheet(result: result) { model.previewResult = nil }
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
            .disabled(model.selectedFolderId == nil || model.isRunningNow)

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
            .disabled(model.selectedFolderId == nil || model.isPreviewing)

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
    public var id: Int { filesScanned.hashValue ^ matches.count.hashValue ^ reachedMatchLimit.hashValue }
}

extension Rule: Identifiable {}

private struct PreviewSheet: View {
    let result: PreviewResult
    let onClose: () -> Void

    private var subtitle: String {
        let matchText = result.reachedMatchLimit
            ? "\(result.matches.count)+ matched"
            : "\(result.matches.count) matched"
        return "\(result.filesScanned) items scanned · \(matchText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(
                title: "Preview (Dry Run)",
                subtitle: subtitle
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
        switch status {
        case .wouldRun: return "Would run"
        case .wouldSkip: return "Would skip"
        case .blockedByConflict: return "Blocked by conflict"
        case .needsConfirmation: return "Needs confirmation"
        }
    }

    var statusIcon: String {
        switch status {
        case .wouldRun: return "arrow.turn.down.right"
        case .wouldSkip: return "minus.circle"
        case .blockedByConflict: return "exclamationmark.triangle.fill"
        case .needsConfirmation: return "questionmark.circle.fill"
        }
    }

    @MainActor var statusColor: Color {
        switch status {
        case .wouldRun: return ForelTheme.accent
        case .wouldSkip: return ForelTheme.secondaryText
        case .blockedByConflict: return .orange
        case .needsConfirmation: return .purple
        }
    }
}
