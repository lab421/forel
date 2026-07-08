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

import AppKit
import SwiftUI
import ForelCore

/// The menu-bar quick panel: header with status badge, a "Watching" master
/// switch, watched-folder toggles, and an activity summary. Deep editing
/// (rules, conditions, actions) stays in the main window; this is the
/// glanceable surface.
struct QuickPanelView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterManager
    let onOpenMainWindow: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack {
            // `.popover` (unlike `.hudWindow`) follows the system/app
            // appearance instead of always rendering dark, so the panel
            // stays legible in Light mode.
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ForelTheme.background.opacity(0.55))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ForelTheme.surfaceBorder, lineWidth: 1)

            VStack(alignment: .leading, spacing: 14) {
                header

                if updater.updateAvailable {
                    UpdateAvailableBanner(
                        version: updater.latestVersion,
                        isInstalling: updater.isInstalling,
                        action: updater.installUpdate
                    )
                }

                GlassCard {
                    ToggleRow(
                        title: "Watching",
                        subtitle: model.paused ? "Paused — new files are ignored" : "Watching folders — rules run automatically",
                        isOn: watchingBinding
                    )
                }

                if !model.folders.isEmpty {
                    SectionLabel(title: "Watched Folders")
                    GlassCard {
                        VStack(spacing: 0) {
                            ForEach(model.folders, id: \.id) { folder in
                                QuickFolderRow(folder: folder, isOn: folderBinding(folder))
                                if folder.id != model.folders.last?.id {
                                    Divider().overlay(ForelTheme.divider).padding(.leading, 50)
                                }
                            }
                        }
                    }
                }

                SectionLabel(title: "Activity")
                HStack(spacing: 10) {
                    StatTile(icon: "folder", label: "Folders", value: "\(model.folders.count)")
                    StatTile(icon: "list.bullet", label: "Rules", value: "\(model.rules.count)")
                    StatTile(icon: "clock.arrow.circlepath", label: "History", value: "\(model.historyTotalCount)")
                }

                SectionLabel(title: "Last 30 Days")
                HStack(spacing: 10) {
                    StatTile(
                        icon: "checkmark.circle.fill",
                        label: "Success",
                        value: "\(model.totalSuccessCount30d)",
                        tint: ForelTheme.success
                    )
                    StatTile(
                        icon: "xmark.circle.fill",
                        label: "Failed",
                        value: "\(model.totalFailedCount30d)",
                        tint: model.totalFailedCount30d > 0 ? ForelTheme.danger : ForelTheme.secondaryText
                    )
                }

                Divider().overlay(ForelTheme.divider)

                HStack(spacing: 8) {
                    QuickPanelFooterButton(title: "Open Forel", systemImage: "arrow.up.forward.app", action: onOpenMainWindow)
                    QuickPanelFooterButton(title: "Quit", systemImage: "power", action: onQuit)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 14)
            .frame(width: 320)
        }
        .padding(1)
        .onAppear {
            model.reloadFolders()
            model.reloadHistory()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text("Forel")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ForelTheme.primaryText)
                StatusBadge(active: !model.paused)
            }
            Spacer(minLength: 0)
        }
    }

    private var watchingBinding: Binding<Bool> {
        Binding(get: { !model.paused }, set: { enabled in
            if enabled == model.paused {
                model.togglePaused()
            }
        })
    }

    private func folderBinding(_ folder: WatchedFolder) -> Binding<Bool> {
        Binding(
            get: {
                model.folders.first { $0.id == folder.id }?.enabled ?? folder.enabled
            },
            set: { model.toggleFolder(folder, enabled: $0) }
        )
    }
}
