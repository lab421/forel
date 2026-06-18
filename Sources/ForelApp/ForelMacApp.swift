import SwiftUI
import ForelCore

@main
struct ForelMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var updater: UpdaterManager

    init() {
        let model = try! AppModel()
        _model = StateObject(wrappedValue: model)
        _updater = StateObject(wrappedValue: UpdaterManager(db: model.db))
    }

    var body: some Scene {
        WindowGroup("Forel") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 960, minHeight: 520)
                .onAppear {
                    appDelegate.configure(model: model, updater: updater)
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 620)
    }
}
