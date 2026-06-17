import SwiftUI
import ForelCore

/// The menu-bar quick panel: header with status badge, a "Watching" master
/// switch, watched-folder toggles, and an activity summary — styled after
/// Vorssaint's dark glass popover. Deep editing (rules, conditions, actions)
/// stays in the main window; this is the glanceable surface.
struct QuickPanelView: View {
    @EnvironmentObject var model: AppModel
    let onOpenMainWindow: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.18))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)

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
                    FooterLink(title: "Settings", systemImage: "gearshape") {
                        model.detailRoute = .settings
                        onOpenMainWindow()
                    }
                    Spacer()
                    FooterLink(title: "Quit", systemImage: "power", action: onQuit)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
        .padding(1)
        .onAppear {
            model.reloadFolders()
            model.reloadHistory()
        }
    }

    private var header: some View {
        ViewHeader(title: "Forel", subtitle: "File automation") {
            StatusBadge(active: !model.paused)
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
