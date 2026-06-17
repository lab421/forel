import SwiftUI
import ForelCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHistory = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if showHistory {
                HistoryView(showHistory: $showHistory)
            } else {
                RuleListView(showHistory: $showHistory)
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
        .tint(ForelTheme.accent)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}
