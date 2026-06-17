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
            ViewHeader(title: "Activity", subtitle: "\(model.history.count) recorded action\(model.history.count == 1 ? "" : "s")") {
                Button {
                    model.detailRoute = .rules
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(IconButtonStyle())
                .help("Back to rules")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                            VStack(spacing: 0) {
                                ForEach(Array(batch.entries.enumerated()), id: \.element.id) { index, entry in
                                    HistoryRow(entry: entry)
                                    if index != batch.entries.count - 1 {
                                        Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ForelTheme.surface))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
                        }
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
                Text("\((entry.originalPath as NSString).lastPathComponent) → \((entry.resultPath as NSString).lastPathComponent)")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if entry.status == .undone {
                Text("Undone")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ForelTheme.surface))
            } else if entry.reversible {
                Button("Undo") { model.undo(entry) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }

    private var label: String {
        ConditionEditorLabels.actionKinds.first { $0.0 == entry.actionKind }?.1 ?? entry.actionKind.rawValue
    }

    private var icon: String {
        switch entry.actionKind {
        case .moveToFolder: return "arrow.right.doc.on.clipboard"
        case .copyToFolder: return "doc.on.doc"
        case .rename: return "pencil"
        case .moveToTrash, .delete: return "trash"
        case .addTag, .removeTag: return "tag"
        case .setColorLabel: return "paintpalette"
        case .runScript: return "terminal"
        }
    }
}
