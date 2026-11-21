import SwiftUI
import ForelCore

struct CopyRulesSheet: View {
    let ruleCount: Int
    let sourceFolderID: String
    let folders: [WatchedFolder]
    let isPro: Bool
    let onCopy: (String) throws -> Void
    let onCancel: () -> Void
    @State private var destinationFolderID = ""
    @State private var errorMessage: String?

    private var destinations: [WatchedFolder] {
        folders.filter { $0.id != sourceFolderID }
    }

    private func isAllowed(_ folder: WatchedFolder) -> Bool {
        FreePlan.allows(folderID: folder.id, folders: folders, isPro: isPro)
    }

    private var canCopy: Bool {
        destinations.contains { $0.id == destinationFolderID && isAllowed($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewHeader(
                title: L10n.plural("copy_rules_title", ruleCount),
                subtitle: L10n.string("copy_rules_choose_another_watched_folder"),
                systemImage: "doc.on.doc"
            )

            if destinations.isEmpty {
                Text(L10n.string("copy_rules_add_another_watched_folder"))
                    .foregroundStyle(ForelTheme.secondaryText)
            } else {
                Picker(L10n.string("destination"), selection: $destinationFolderID) {
                    Text(L10n.string("copy_rules_choose_a_folder")).tag("")
                    ForEach(destinations, id: \.id) { folder in
                        Text(isAllowed(folder) ? folder.path : L10n.string("copy_rules_pro", folder.path))
                            .tag(folder.id)
                            .disabled(!isAllowed(folder))
                    }
                }
                .pickerStyle(.menu)

                if !destinations.contains(where: isAllowed) {
                    Text(L10n.string("copy_rules_reorder_watched_folders_activate"))
                        .font(.callout)
                        .foregroundStyle(ForelTheme.secondaryText)
                }
            }

            Text(L10n.string("copy_rules_copies_independent_keep_their"))
                .font(.callout)
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(L10n.string("cancel"), action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("copy_rules_copy")) {
                    do { try onCopy(destinationFolderID) }
                    catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canCopy)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(ForelTheme.background)
        .onAppear {
            destinationFolderID = destinations.first(where: isAllowed)?.id ?? ""
        }
    }
}
