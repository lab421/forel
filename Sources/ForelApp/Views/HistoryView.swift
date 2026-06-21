import SwiftUI
import ForelCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    private var batches: [(id: String, entries: [HistoryEntry])] {
        let grouped = Dictionary(grouping: model.history, by: \.batchId)
        return grouped
            .map { (id: $0.key, entries: $0.value) }
            .sorted { ($0.entries.first?.createdAt ?? "") > ($1.entries.first?.createdAt ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(title: "Activity", subtitle: "\(model.historyTotalCount) recorded action\(model.historyTotalCount == 1 ? "" : "s")", systemImage: "clock.arrow.circlepath") {
                Button {
                    model.detailRoute = .rules
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(IconButtonStyle())
                .help("Back to rules")
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ForelTheme.secondaryText)
                Picker("Directory", selection: Binding(
                    get: { model.historyFolderFilterId ?? "" },
                    set: { model.setHistoryFolderFilter($0.isEmpty ? nil : $0) }
                )) {
                    Text("All directories").tag("")
                    ForEach(model.folders, id: \.id) { folder in
                        Text((folder.path as NSString).lastPathComponent).tag(folder.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)

                Spacer()

                if model.isLoadingHistory {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(batches, id: \.id) { batch in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                SectionLabel(title: relativeLabel(batch.entries.first?.createdAt))
                                Spacer()
                                if undoableCount(batch.entries) > 0 {
                                    Button("Undo Batch (\(undoableCount(batch.entries)))") {
                                        model.undoBatch(batch.id)
                                    }
                                    .buttonStyle(SecondaryButtonStyle())
                                }
                            }
                            BatchHistorySection(entries: batch.entries)
                        }
                    }

                    if model.hasMoreHistory {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .onAppear { model.loadMoreHistoryIfNeeded() }
                    }

                    if batches.isEmpty {
                        emptyState
                    }
                }
            }
            .scrollIndicators(.never)

            if !batches.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear History", role: .destructive) {
                        try? model.db.clearHistory()
                        model.reloadHistory()
                    }
                    .buttonStyle(SecondaryButtonStyle(role: .destructive))
                }
            }
        }
        .padding(16)
        .frame(minWidth: 460)
        .background(ForelTheme.background)
        .onAppear { model.reloadHistory() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(ForelTheme.secondaryText)
            Text("No activity yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ForelTheme.primaryText)
            Text("Actions performed by your rules will appear here.")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    /// Number of still-applied, reversible entries in a batch — drives whether
    /// the per-batch undo button is shown and its count.
    private func undoableCount(_ entries: [HistoryEntry]) -> Int {
        entries.filter { $0.status == .applied && $0.reversible }.count
    }

    /// Shows the leading portion of the ISO timestamp; good enough as a header
    /// without pulling in date parsing for the grouped batch label.
    private func relativeLabel(_ iso: String?) -> String {
        guard let iso, iso.count >= 16 else { return "Earlier" }
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

private struct HistoryFileGroup: Identifiable {
    let id: String
    var paths: Set<String>
    var entries: [HistoryEntry]

    var title: String {
        let path = entries.first?.originalPath ?? id
        return (path as NSString).lastPathComponent
    }
}

private struct BatchHistorySection: View {
    @EnvironmentObject var model: AppModel
    let entries: [HistoryEntry]

    private var groups: [HistoryFileGroup] {
        var groups: [HistoryFileGroup] = []
        for entry in entries {
            let touched = Set([entry.originalPath, entry.resultPath])
            if let index = groups.firstIndex(where: { !$0.paths.isDisjoint(with: touched) }) {
                groups[index].paths.formUnion(touched)
                groups[index].entries.append(entry)
            } else {
                groups.append(HistoryFileGroup(id: entry.id, paths: touched, entries: [entry]))
            }
        }
        return groups
    }

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        HistoryRow(entry: entry)
                            .onAppear { model.loadMoreHistoryIfNeeded(currentEntry: entry) }
                        if index != group.entries.count - 1 {
                            Divider().overlay(ForelTheme.divider).padding(.leading, 46)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
            }
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ForelTheme.accent.opacity(0.16))
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(ForelTheme.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.ruleName) · \(label)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                Text("\(entry.originalPath) → \(entry.resultPath)")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message = entry.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if entry.status == .undone {
                statusBadge
            } else if entry.status == .applied && entry.reversible {
                Button("Undo") { model.undo(entry) }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                statusBadge
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private var label: String {
        entry.actionKind.label
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    private var statusLabel: String {
        switch entry.status {
        case .applied: return "Applied"
        case .undone: return "Undone"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .needsConfirmation: return "Needs confirmation"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .applied: return ForelTheme.accent
        case .undone, .skipped: return ForelTheme.secondaryText
        case .failed: return ForelTheme.danger
        case .needsConfirmation: return .orange
        }
    }

    private var icon: String {
        entry.actionKind.iconSystemName
    }
}
