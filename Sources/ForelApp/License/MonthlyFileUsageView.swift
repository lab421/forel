import SwiftUI
import ForelCore

struct MonthlyFileUsageView: View {
    @EnvironmentObject private var model: AppModel
    var onUpgrade: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            if let usage = model.monthlyFileUsage {
                Button {
                    if let onUpgrade { onUpgrade() }
                    else { model.proUpgrade = .monthlyFiles }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.string("usage_files_this_month", usage.processed, FreePlan.monthlyFileLimit))
                            .font(.caption.monospacedDigit())
                        ProgressView(value: Double(usage.processed), total: Double(FreePlan.monthlyFileLimit))
                            .tint(usage.isExhausted ? ForelTheme.pro : ForelTheme.accent)
                    }
                    .foregroundStyle(ForelTheme.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("usage_renews_dry_run_count", usage.resetsAt.formatted(date: .abbreviated, time: .omitted)))
            }
        }
    }
}
