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
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var draggedFolderId: String?
    @State private var insertionIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewHeader(title: "Forel", subtitle: "File automation") {
                StatusBadge(active: !model.paused)
            }

            HStack {
                SectionLabel(title: "Watched Folders")
                Spacer()
                Button(action: addFolder) {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle())
                .help("Add a folder to watch")
            }

            if model.folders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.folders.enumerated()), id: \.element.id) { index, folder in
                            folderDropTarget(index)

                            folderCard(folder)
                                .opacity(draggedFolderId == folder.id ? 0.55 : 1)
                                .onDrag {
                                    draggedFolderId = folder.id
                                    return NSItemProvider(object: folder.id as NSString)
                                }
                                .onDrop(
                                    of: [.plainText],
                                    delegate: FolderInsertionDropDelegate(
                                        insertionIndex: index,
                                        folders: model.folders,
                                        draggedFolderId: $draggedFolderId,
                                        activeInsertionIndex: $insertionIndex,
                                        move: model.reorderFolders
                                    )
                                )
                        }
                        folderDropTarget(model.folders.count)
                    }
                    .animation(.easeInOut(duration: 0.12), value: insertionIndex)
                    .onDrop(
                        of: [.plainText],
                        delegate: FolderInsertionDropDelegate(
                            insertionIndex: model.folders.count,
                            folders: model.folders,
                            draggedFolderId: $draggedFolderId,
                            activeInsertionIndex: $insertionIndex,
                            move: model.reorderFolders
                        )
                    )
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)

            HStack {
                if #available(macOS 14.0, *) {
                    SettingsFooterLink()
                } else {
                    FooterLink(title: "Settings", systemImage: "gearshape") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                    .help("Settings")
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 250)
        .background(ForelTheme.background)
    }

    private func folderDropTarget(_ index: Int) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 10)

            if insertionIndex == index, draggedFolderId != nil {
                Capsule()
                    .fill(ForelTheme.accent)
                    .frame(height: 2)
                    .shadow(color: ForelTheme.accent.opacity(0.35), radius: 2, y: 1)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [.plainText],
            delegate: FolderInsertionDropDelegate(
                insertionIndex: index,
                folders: model.folders,
                draggedFolderId: $draggedFolderId,
                activeInsertionIndex: $insertionIndex,
                move: model.reorderFolders
            )
        )
    }

    private func folderCard(_ folder: WatchedFolder) -> some View {
        let isSelected = model.selectedFolderId == folder.id
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText.opacity(0.6))

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
            Button("Change path of folder…") { changeFolder(folder) }
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

    private func changeFolder(_ folder: WatchedFolder) {
        if let path = FolderPicker.choose(startingAt: folder.path) {
            model.updateFolderPath(folder, path: path)
        }
    }
}

@available(macOS 14.0, *)
private struct SettingsFooterLink: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        FooterLink(title: "Settings", systemImage: "gearshape") {
            openSettings()
        }
        .help("Settings")
    }
}

private struct FolderInsertionDropDelegate: DropDelegate {
    let insertionIndex: Int
    let folders: [WatchedFolder]
    @Binding var draggedFolderId: String?
    @Binding var activeInsertionIndex: Int?
    let move: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedFolderId != nil else { return }
        activeInsertionIndex = insertionIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        activeInsertionIndex = insertionIndex
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedFolderId = nil
            activeInsertionIndex = nil
        }

        guard
            let draggedFolderId,
            let sourceIndex = folders.firstIndex(where: { $0.id == draggedFolderId })
        else { return false }

        var ids = folders.map(\.id)
        ids.remove(at: sourceIndex)
        let targetIndex = sourceIndex < insertionIndex ? insertionIndex - 1 : insertionIndex
        let boundedTargetIndex = max(0, min(targetIndex, ids.count))
        ids.insert(draggedFolderId, at: boundedTargetIndex)

        guard ids != folders.map(\.id) else { return true }
        move(ids)
        return true
    }
}
