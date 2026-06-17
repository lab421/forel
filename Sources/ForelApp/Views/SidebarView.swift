import SwiftUI
import ForelCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(title: "Forel", subtitle: "File automation")

            HStack {
                SectionLabel(title: "Watched Folders")
                Spacer()
                Button(action: addFolder) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle())
                .help("Add a folder to watch")
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.folders, id: \.id) { folder in
                        folderCard(folder)
                    }

                    if model.folders.isEmpty {
                        emptyState
                    }
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            HStack {
                FooterLink(title: "Settings", systemImage: "gearshape") {
                    model.detailRoute = .settings
                }
                .help("Settings")
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 250)
        .background(ForelTheme.background)
    }

    private func folderCard(_ folder: WatchedFolder) -> some View {
        let isSelected = model.selectedFolderId == folder.id
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(ForelTheme.accent.opacity(folder.enabled ? 0.18 : 0.08))
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(folder.enabled ? ForelTheme.accent : ForelTheme.secondaryText)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text((folder.path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ForelTheme.primaryText)
                    .lineLimit(1)
                Text((folder.path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            ForelSwitch(isOn: enabledBinding(folder), compact: true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? ForelTheme.accent.opacity(0.14) : ForelTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? ForelTheme.accent.opacity(0.5) : ForelTheme.surfaceBorder)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedFolderId = folder.id
            model.detailRoute = .rules
            model.reloadRules()
        }
        .contextMenu {
            Button("Remove", role: .destructive) { model.removeFolder(folder) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(ForelTheme.secondaryText)
            Text("No folders yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ForelTheme.primaryText)
            Text("Add a folder to start automating files.")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Add Folder", action: addFolder)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func enabledBinding(_ folder: WatchedFolder) -> Binding<Bool> {
        Binding(get: { folder.enabled }, set: { model.toggleFolder(folder, enabled: $0) })
    }

    private func addFolder() {
        if let path = FolderPicker.choose() {
            model.addFolder(path: path)
        }
    }
}
