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
                        Text("\(usage.processed)/\(FreePlan.monthlyFileLimit) files this month")
                            .font(.caption.monospacedDigit())
                        ProgressView(value: Double(usage.processed), total: Double(FreePlan.monthlyFileLimit))
                            .tint(usage.isExhausted ? ForelTheme.pro : ForelTheme.accent)
                    }
                    .foregroundStyle(ForelTheme.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Renews \(usage.resetsAt.formatted(date: .abbreviated, time: .omitted)). Dry Run does not count. Discover Pro for unlimited processing.")
            }
        }
    }
}
