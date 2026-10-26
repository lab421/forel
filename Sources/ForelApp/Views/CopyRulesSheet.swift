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
                title: ruleCount == 1 ? "Copy Rule" : "Copy \(ruleCount) Rules",
                subtitle: "Choose another watched folder",
                systemImage: "doc.on.doc"
            )

            if destinations.isEmpty {
                Text("Add another watched folder to copy rules to it.")
                    .foregroundStyle(ForelTheme.secondaryText)
            } else {
                Picker("Destination", selection: $destinationFolderID) {
                    Text("Choose a folder").tag("")
                    ForEach(destinations, id: \.id) { folder in
                        Text(isAllowed(folder) ? folder.path : "\(folder.path) — Pro")
                            .tag(folder.id)
                            .disabled(!isAllowed(folder))
                    }
                }
                .pickerStyle(.menu)

                if !destinations.contains(where: isAllowed) {
                    Text("Reorder your watched folders or activate Pro to use these destinations.")
                        .font(.callout)
                        .foregroundStyle(ForelTheme.secondaryText)
                }
            }

            Text("Copies are independent and keep their conditions, actions, and enabled state. Action destinations stay unchanged.")
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
                Button("Cancel", action: onCancel)
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
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
