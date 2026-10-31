// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One-time, opt-in handoff from Hazel's per-folder export menu.
struct HazelImportAssistantView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(ForelTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import your Hazel rules?")
                        .font(.system(size: 20, weight: .bold))
                    Text("Hazel was found on this Mac.")
                        .foregroundStyle(ForelTheme.secondaryText)
                }
            }

            Text("Forel can import Hazel’s rule export and will flag anything it cannot reproduce exactly for your review.")
                .font(.system(size: 13))
                .foregroundStyle(ForelTheme.primaryText)

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Choose the folder to receive the imported rules.") {
                    Button(model.selectedFolderId == nil ? "Choose Folder…" : "Choose Different Folder…") {
                        if let path = FolderPicker.choose() { model.addFolder(path: path) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                step(2, "Open Hazel, select that folder, then choose ••• → Export Rules…") {
                    Button("Open Hazel", action: model.openHazel)
                        .buttonStyle(SecondaryButtonStyle())
                }
                step(3, "Return here and select the .hazelrules file Hazel saved.") {
                    Button("Choose Hazel Export…", action: chooseHazelExport)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.selectedFolderId == nil)
                }
            }

            HStack {
                Spacer()
                Button("Not Now", action: model.finishHazelImportAssistant)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }

    private func step<Content: View>(_ number: Int, _ text: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(ForelTheme.accent))
            VStack(alignment: .leading, spacing: 7) {
                Text(text).font(.system(size: 13, weight: .medium))
                content()
            }
        }
    }

    private func chooseHazelExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "hazelrules") ?? .data]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.importRules(from: url) { model.finishHazelImportAssistant() }
    }
}
