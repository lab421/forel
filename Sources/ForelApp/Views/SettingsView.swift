import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterManager
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: "Appearance")
                    GlassCard {
                        PickerRow(title: "Theme", selection: themeBinding) {
                            Text("System").tag(AppTheme.system)
                            Text("Light").tag(AppTheme.light)
                            Text("Dark").tag(AppTheme.dark)
                        }
                        Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Accent color").font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
                            AccentColorPicker(selection: accentBinding)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                    }

                    SectionLabel(title: "General")
                    GlassCard {
                        ToggleRow(
                            title: "Start at login",
                            subtitle: "Open Forel automatically when you log in",
                            isOn: launchAtLoginBinding
                        )
                        Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                        ToggleRow(
                            title: "Show Dock icon",
                            subtitle: "Keep Forel visible in the Dock while it runs",
                            isOn: dockIconBinding
                        )
                        Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Keep history for").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                                Spacer()
                                Text("\(model.historyMaxDays) day\(model.historyMaxDays > 1 ? "s" : "")").font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                            }
                            Slider(value: historyMaxDaysDoubleBinding, in: 1...30, step: 1)
                                .tint(ForelTheme.accent)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                    }

                    SectionLabel(title: "Updates")
                    if updater.updateAvailable {
                        UpdateAvailableBanner(
                            version: updater.latestVersion,
                            isInstalling: updater.isInstalling,
                            action: updater.installUpdate
                        )
                    }
                    GlassCard {
                        ToggleRow(
                            title: "Automatic updates",
                            subtitle: "Check for new versions in the background",
                            isOn: automaticUpdatesBinding
                        )
                        Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                        SettingsActionRow(
                            title: "Current version",
                            subtitle: versionSubtitle,
                            buttonTitle: "Check Now",
                            action: { updater.checkForUpdates() }
                        )
                        .disabled(updater.isChecking || updater.isInstalling || updater.updateAvailable)
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
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 460)
        .background(ForelTheme.background)
        .onAppear {
            let storedLogin = (try? model.db.getSetting("launch_at_login")) ?? nil
            launchAtLogin = LoginItem.isEnabled || storedLogin == "1"
        }
    }

    private var header: some View {
        ViewHeader(title: "Settings", subtitle: "Forel preferences", systemImage: "gearshape") {
            Button {
                model.detailRoute = .rules
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(IconButtonStyle())
            .help("Back to rules")
        }
    }

    private var accentBinding: Binding<AccentPreset> {
        Binding(get: { model.accentPreset }, set: { model.setAccentPreset($0) })
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { model.appTheme }, set: { model.setAppTheme($0) })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { enabled in
            launchAtLogin = enabled
            try? model.db.setSetting("launch_at_login", enabled ? "1" : "0")
            // In a signed .app this registers/unregisters the login item; in an
            // unsigned dev build it fails silently — the preference is still
            // saved and applies once running from a packaged build.
            LoginItem.setEnabled(enabled)
        })
    }

    private var dockIconBinding: Binding<Bool> {
        Binding(get: { model.showDockIcon }, set: { model.setShowDockIcon($0) })
    }

    private var historyMaxDaysBinding: Binding<Int> {
        Binding(get: { model.historyMaxDays }, set: { model.setHistoryMaxDays($0) })
    }

    private var historyMaxDaysDoubleBinding: Binding<Double> {
        Binding(get: { Double(model.historyMaxDays) }, set: { model.setHistoryMaxDays(Int($0)) })
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 })
    }

    private var versionSubtitle: String {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "alpha"
        if updater.isChecking { return "\(current) — Checking…" }
        return current
    }
}
