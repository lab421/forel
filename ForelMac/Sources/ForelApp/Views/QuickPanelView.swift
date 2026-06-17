import SwiftUI
import ForelCore

/// The menu-bar quick panel: header with status badge, a "Watching" master
/// switch, watched-folder toggles, and an activity summary — styled after
/// Vorssaint's dark glass popover. Deep editing (rules, conditions, actions)
/// stays in the main window; this is the glanceable surface.
struct QuickPanelView: View {
    @EnvironmentObject var model: AppModel
    let onOpenMainWindow: () -> Void
    let onCheckForUpdates: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            GlassCard {
                ToggleRow(
                    title: "Watching",
                    subtitle: model.paused ? "Paused — new files are ignored" : "Rules run automatically on new files",
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
                StatTile(icon: "clock.arrow.circlepath", label: "History", value: "\(model.history.count)")
            }

            Divider().overlay(ForelTheme.divider)

            HStack {
                FooterLink(title: "Open Forel", systemImage: "arrow.up.forward.app", action: onOpenMainWindow)
                Spacer()
                FooterLink(title: "Check for Updates", systemImage: "arrow.triangle.2.circlepath", action: onCheckForUpdates)
                Spacer()
                FooterLink(title: "Quit", systemImage: "power", action: onQuit)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(ForelTheme.background)
        .onAppear { model.reloadHistory() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black)
                Image(systemName: "wand.and.stars").foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Forel").font(.system(size: 15, weight: .bold)).foregroundStyle(ForelTheme.primaryText)
                Text("File automation").font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
            }
            Spacer()
            StatusBadge(active: !model.paused)
        }
    }

    private var watchingBinding: Binding<Bool> {
        Binding(get: { !model.paused }, set: { _ in model.togglePaused() })
    }

    private func folderBinding(_ folder: WatchedFolder) -> Binding<Bool> {
        Binding(get: { folder.enabled }, set: { model.toggleFolder(folder, enabled: $0) })
    }
}
