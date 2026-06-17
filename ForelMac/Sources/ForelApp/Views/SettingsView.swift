import SwiftUI
import ServiceManagement

private enum AppTheme: String, CaseIterable {
    case system, light, dark
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterManager
    @State private var theme: AppTheme = .system
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            SectionLabel(title: "Appearance")
            GlassCard {
                PickerRow(title: "Theme", selection: themeBinding) {
                    Text("System").tag(AppTheme.system)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                }
            }

            SectionLabel(title: "General")
            GlassCard {
                ToggleRow(
                    title: "Launch at login",
                    subtitle: "Open Forel automatically when you log in",
                    isOn: launchAtLoginBinding
                )
            }

            SectionLabel(title: "Updates")
            GlassCard {
                ToggleRow(
                    title: "Automatic updates",
                    subtitle: "Check for new versions in the background",
                    isOn: automaticUpdatesBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                SettingsActionRow(
                    title: "Current version",
                    subtitle: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "alpha",
                    buttonTitle: "Check Now",
                    action: { updater.checkForUpdates() }
                )
            }

            SectionLabel(title: "About")
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Forel").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                        Text("Open-source file automation for macOS").font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 420)
        .background(ForelTheme.background)
        .preferredColorScheme(.dark)
        .onAppear {
            let stored = (try? model.db.getSetting("theme")) ?? nil
            theme = AppTheme(rawValue: stored ?? "system") ?? .system
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black)
                Image(systemName: "wand.and.stars").foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("Settings").font(.system(size: 15, weight: .bold)).foregroundStyle(ForelTheme.primaryText)
                Text("Forel preferences").font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
            }
            Spacer()
        }
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { theme }, set: { newValue in
            theme = newValue
            try? model.db.setSetting("theme", newValue.rawValue)
        })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { enabled in
            launchAtLogin = enabled
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                model.errorMessage = "\(error)"
            }
        })
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 })
    }
}
