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
import Lab421Licensing

/// Shared across the app delegate and `SettingsView` so code outside SwiftUI
/// (e.g. the status item's "Activate" action, or `AppDelegate` reacting to a
/// denied license) can select a specific settings tab before opening the
/// `Settings` scene.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedCategory: SettingsCategory = .general
}

/// Modern macOS Settings layout: a category sidebar on the left (matching
/// System Settings' own convention), detail content on the right — instead
/// of one long scrolling list of sections.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterManager
    @EnvironmentObject var license: ForelLicenseManager
    @EnvironmentObject var navigation: SettingsNavigation
    @State private var launchAtLogin = LoginItem.isEnabled
    /// "" follows the Mac's language.
    @State private var languageChoice = AppLanguage.choice ?? ""
    @State private var nextLanguage = AppLanguage.next

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(ForelTheme.divider)
            detail
        }
        .frame(width: 600, height: 440)
        .background(ForelTheme.background)
        .navigationTitle(L10n.string("settings"))
        .onAppear {
            let storedLogin = (try? model.db.getSetting("launch_at_login")) ?? nil
            launchAtLogin = LoginItem.isEnabled || storedLogin == "1"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { category in
                SettingsSidebarRow(
                    category: category,
                    isSelected: navigation.selectedCategory == category,
                    action: { navigation.selectedCategory = category }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 170, alignment: .top)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch navigation.selectedCategory {
                case .general:
                    generalPane
                case .permissions:
                    PermissionsSection()
                case .license:
                    LicenseSettingsView()
                        .environmentObject(license)
                case .updates:
                    updatesPane
                case .about:
                    aboutPane
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var generalPane: some View {
        Group {
            SectionLabel(title: L10n.string("settings_appearance"))
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("settings_accent_color")).font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
                    AccentColorPicker(selection: accentBinding)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                if AppLanguage.available.count > 1 {
                    Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                    languageRow
                }
            }

            SectionLabel(title: L10n.string("settings_general"))
            GlassCard {
                ToggleRow(
                    title: L10n.string("settings_automatic_watching"),
                    subtitle: model.paused ? L10n.string("paused_new_files_ignored") : L10n.string("watching_folders_rules_run"),
                    isOn: watchingBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                ToggleRow(
                    title: L10n.string("settings_start_at_login"),
                    subtitle: L10n.string("settings_open_forel_automatically_when"),
                    isOn: launchAtLoginBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                ToggleRow(
                    title: L10n.string("settings_show_dock_icon"),
                    subtitle: L10n.string("settings_keep_forel_visible_dock"),
                    isOn: dockIconBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                ToggleRow(
                    title: L10n.string("settings_watcher_notifications"),
                    subtitle: L10n.string("settings_notify_when_automatic_rules"),
                    isOn: watcherNotificationsBinding
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.string("settings_keep_history_for")).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                        Spacer()
                        Text(L10n.plural("settings_days", model.historyMaxDays)).font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                    }
                    Slider(value: historyMaxDaysDoubleBinding, in: 1...30, step: 1)
                        .tint(ForelTheme.accent)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }
        }
    }

    private var updatesPane: some View {
        Group {
            SectionLabel(title: L10n.string("settings_updates"))
            if updater.updateAvailable {
                UpdateAvailableBanner(
                    version: updater.latestVersion,
                    isInstalling: updater.isInstalling,
                    action: updater.installUpdate
                )
            }
            GlassCard {
                ToggleRow(
                    title: L10n.string("settings_automatic_updates"),
                    subtitle: L10n.string("settings_check_new_versions_background"),
                    isOn: $updater.automaticallyChecksForUpdates
                )
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                SettingsActionRow(
                    title: L10n.string("settings_current_version"),
                    subtitle: versionSubtitle,
                    buttonTitle: L10n.string("settings_check_now"),
                    action: { updater.checkForUpdates() }
                )
                .disabled(updater.isChecking || updater.isInstalling || updater.updateAvailable)
            }
        }
    }

    private var aboutPane: some View {
        Group {
            SectionLabel(title: L10n.string("settings_about"))
            GlassCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppInfo.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                        Text(AppInfo.tagline).font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                aboutRow(title: L10n.string("settings_version"), value: AppInfo.version)
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                aboutRow(title: L10n.string("settings_build"), value: AppInfo.build)
                if let copyright = AppInfo.copyright {
                    Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                    aboutRow(title: L10n.string("settings_copyright"), value: copyright)
                }
                Divider().overlay(ForelTheme.divider).padding(.leading, 14)
                HStack {
                    Text(L10n.string("github_repository")).font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
                    Spacer()
                    Link(L10n.string("settings_lab421_forel"), destination: AppInfo.repositoryURL)
                        .font(.system(size: 12))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
            }
        }
    }

    private func aboutRow(title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(ForelTheme.secondaryText)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("settings_language")).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                    Text(L10n.string("settings_applies_forel_only_like"))
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker(L10n.string("settings_language"), selection: languageBinding) {
                    Text(L10n.string("settings_same_as_macos")).tag("")
                    Divider()
                    ForEach(AppLanguage.available, id: \.self) { code in
                        Text(verbatim: AppLanguage.nativeName(code)).tag(code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if nextLanguage != AppLanguage.current {
                HStack(spacing: 8) {
                    Text(L10n.string("settings_forel_switches_when_relaunches", AppLanguage.displayName(nextLanguage)))
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.string("settings_relaunch_now"), action: AppLanguage.relaunch)
                        .controlSize(.small)
                        .disabled(relaunchBlocker != nil)
                        .help(relaunchBlocker ?? "")
                }
                if let relaunchBlocker {
                    Text(relaunchBlocker)
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { languageChoice },
            set: { code in
                languageChoice = code
                AppLanguage.choice = code.isEmpty ? nil : code
                nextLanguage = AppLanguage.next
            }
        )
    }

    /// Why relaunching now would lose work, if it would.
    private var relaunchBlocker: String? {
        if model.editorHasUnsavedChanges {
            return L10n.string("settings_save_discard_changes_rule")
        }
        if model.isRunningNow || model.isPreviewing {
            return L10n.string("settings_wait_run_now_dry")
        }
        return nil
    }

    private var accentBinding: Binding<AccentPreset> {
        Binding(get: { model.accentPreset }, set: { model.setAccentPreset($0) })
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

    private var watcherNotificationsBinding: Binding<Bool> {
        Binding(get: { model.watcherNotificationsEnabled }, set: { model.setWatcherNotificationsEnabled($0) })
    }

    private var watchingBinding: Binding<Bool> {
        Binding(get: { !model.paused }, set: { enabled in
            if enabled == model.paused {
                model.togglePaused()
            }
        })
    }

    private var historyMaxDaysBinding: Binding<Int> {
        Binding(get: { model.historyMaxDays }, set: { model.setHistoryMaxDays($0) })
    }

    private var historyMaxDaysDoubleBinding: Binding<Double> {
        Binding(get: { Double(model.historyMaxDays) }, set: { model.setHistoryMaxDays(Int($0)) })
    }

    private var versionSubtitle: String {
        let current = AppInfo.version
        if updater.isChecking { return L10n.string("settings_checking", current) }
        return current
    }
}

enum SettingsCategory: CaseIterable, Identifiable {
    case general, permissions, license, updates, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L10n.string("settings_general")
        case .permissions: L10n.string("permissions")
        case .license: L10n.string("settings_license")
        case .updates: L10n.string("settings_updates")
        case .about: L10n.string("settings_about")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .permissions: "lock.shield.fill"
        case .license: "key.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(red: 0.36, green: 0.34, blue: 0.90)
        case .permissions: Color(red: 0.95, green: 0.55, blue: 0.13)
        case .license: Color(red: 0.20, green: 0.45, blue: 0.80)
        case .updates: Color(red: 0.20, green: 0.70, blue: 0.45)
        case .about: Color(red: 0.31, green: 0.55, blue: 0.95)
        }
    }
}

private struct SettingsSidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(category.tint)
                    Image(systemName: category.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)

                Text(category.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : ForelTheme.primaryText)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? ForelTheme.accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
