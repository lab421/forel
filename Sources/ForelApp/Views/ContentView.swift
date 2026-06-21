import SwiftUI
import ForelCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterManager

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 270, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            switch model.detailRoute {
            case .rules:
                RuleListView()
            case .history:
                HistoryView()
            case .settings:
                SettingsView()
            }
        }
        .toolbarBackground(ForelTheme.background, for: .windowToolbar)
        .alert(model.alertTitle, isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .preferredColorScheme(model.appTheme.colorScheme)
        .tint(ForelTheme.accent)
        .id(model.accentVersion)
        .sheet(isPresented: $updater.showReleaseNotes) {
            ReleaseNotesView(version: updater.releaseNotes?.version ?? "", markdown: updater.releaseNotes?.body ?? "", url: updater.releaseNotes?.url)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: {
                if !$0 {
                    model.errorMessage = nil
                    model.alertTitle = "Error"
                }
            }
        )
    }
}

private struct ReleaseNotesView: View {
    let version: String
    let markdown: String
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(ForelTheme.accent.opacity(0.18))
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ForelTheme.accent)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("What's New in \(version)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ForelTheme.primaryText)
                    Text("Forel has been updated")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ForelTheme.secondaryText)
            }

            Divider().overlay(ForelTheme.divider)

            ScrollView {
                Text(markdown)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.never)

            HStack {
                if let url {
                    Button("View on GitHub") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Continue") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520, height: 420)
        .background(ForelTheme.background)
    }
}
