import SwiftUI
import ForelCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

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
        // ForelTheme.accent is a plain static var, not observable; bumping the
        // identity here forces every descendant to rebuild and re-read it.
        .id(model.accentVersion)
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
