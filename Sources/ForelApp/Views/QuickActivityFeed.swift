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

/// Paged feed of the most recent actions across all watched folders. Owns its
/// own paging state so it never disturbs the main window's History view (and
/// ignores that view's folder filter).
@MainActor
final class QuickActivityFeedModel: ObservableObject {
    static let pageSize = 10

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var hasMore = false

    private let db: Database

    init(db: Database) {
        self.db = db
    }

    /// Starts over from the newest entries, keeping as many rows as are
    /// already loaded so a refresh doesn't collapse the user's scroll position.
    func reload() {
        let limit = max(Self.pageSize, entries.count)
        let page = db.withLock { db in (try? db.listHistory(limit: limit, offset: 0)) ?? [] }
        entries = page
        hasMore = page.count == limit
    }

    func loadMore() {
        guard hasMore else { return }
        let offset = entries.count
        let page = db.withLock { db in (try? db.listHistory(limit: Self.pageSize, offset: offset)) ?? [] }
        entries += page
        hasMore = page.count == Self.pageSize
    }
}

struct QuickActivityFeed: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var feed: QuickActivityFeedModel

    init(db: Database) {
        _feed = StateObject(wrappedValue: QuickActivityFeedModel(db: db))
    }

    var body: some View {
        GlassCard {
            if feed.entries.isEmpty {
                Text("No activity yet")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(feed.entries, id: \.id) { entry in
                            QuickActivityRow(entry: entry)
                            if entry.id != feed.entries.last?.id || feed.hasMore {
                                Divider().overlay(ForelTheme.divider).padding(.leading, 44)
                            }
                        }
                        if feed.hasMore {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .onAppear { feed.loadMore() }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: 220)
            }
        }
        .onAppear { feed.reload() }
        // New actions (watcher, Run Now, undo) change the total — pick them up
        // while the panel is open.
        .onReceive(model.$historyTotalCount.dropFirst()) { _ in feed.reload() }
    }
}

private struct QuickActivityRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: entry.actionKind.iconSystemName)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text((entry.originalPath as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.ruleName) · \(entry.actionKind.label)")
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                if let when = HistoryTimestampFormatter.relative(entry.createdAt) {
                    Text(when)
                        .font(.system(size: 10))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
                if let badge = statusBadge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .help("\(entry.originalPath) → \(entry.resultPath)")
    }

    private var statusBadge: String? {
        switch entry.status {
        case .applied: return nil
        case .undone: return "Undone"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .needsConfirmation: return "Needs confirmation"
        }
    }

    private var tint: Color {
        switch entry.status {
        case .applied: return ForelTheme.accent
        case .undone, .skipped: return ForelTheme.secondaryText
        case .failed: return ForelTheme.danger
        case .needsConfirmation: return .orange
        }
    }
}
