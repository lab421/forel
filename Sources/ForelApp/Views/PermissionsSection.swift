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
import AppKit
import ForelCore

/// Centralizes every system permission Forel depends on — Photos and
/// Music/TV automation — in one place, so the user can see at a glance what's
/// granted and fix what isn't, instead of discovering a missing permission
/// only when a rule silently fails.
struct PermissionsSection: View {
    @State private var photosStatus: PermissionStatus = .unknown
    @State private var musicStatus: PermissionStatus = .unknown
    @State private var tvStatus: PermissionStatus = .unknown
    @State private var isCheckingMusic = false
    @State private var isCheckingTV = false

    var body: some View {
        SectionLabel(title: "Permissions")
        GlassCard {
            PhotosPermissionRow(status: photosStatus, onRequest: {
                photosStatus = PermissionsChecker.requestPhotosAccess()
            })
            Divider().overlay(ForelTheme.divider).padding(.leading, 14)
            AutomationPermissionRow(
                appName: "Music",
                status: musicStatus,
                isChecking: isCheckingMusic,
                onCheck: { check(app: "Music") }
            )
            Divider().overlay(ForelTheme.divider).padding(.leading, 14)
            AutomationPermissionRow(
                appName: "TV",
                status: tvStatus,
                isChecking: isCheckingTV,
                onCheck: { check(app: "TV") }
            )
        }
        .onAppear {
            photosStatus = PermissionsChecker.photosAccessStatus()
            // `isAppRunning` talks to System Events over AppleScript, which
            // can take a noticeable moment (especially the first time it's
            // launched this session) — run it off the main thread so opening
            // this tab shows the pane right away instead of hitching on it.
            // Only auto-check Music/TV if they're already running — querying
            // automation status otherwise means launching them, which Settings
            // should never do just by being opened (see `onCheck`/`check`).
            Task.detached(priority: .userInitiated) {
                let musicRunning = PermissionsChecker.isAppRunning("Music")
                let tvRunning = PermissionsChecker.isAppRunning("TV")
                await MainActor.run {
                    if musicRunning { check(app: "Music") }
                    if tvRunning { check(app: "TV") }
                }
            }
        }
    }

    private func check(app: String) {
        if app == "Music" { isCheckingMusic = true } else { isCheckingTV = true }
        Task.detached(priority: .userInitiated) {
            let result = PermissionsChecker.checkAutomationAccessNow(app: app)
            await MainActor.run {
                if app == "Music" {
                    musicStatus = result
                    isCheckingMusic = false
                } else {
                    tvStatus = result
                    isCheckingTV = false
                }
            }
        }
    }
}

private struct PhotosPermissionRow: View {
    let status: PermissionStatus
    let onRequest: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                Text("Needed by the Import to Library action when importing photos or videos.")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
            Spacer()
            PermissionStatusBadge(status: status)
            switch status {
            case .unknown:
                Button("Request Access", action: onRequest)
                    .buttonStyle(SecondaryButtonStyle())
            case .denied, .restricted:
                Button("Open Settings") { SystemSettings.openPrivacyPane(.photos) }
                    .buttonStyle(SecondaryButtonStyle())
            case .granted:
                EmptyView()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

private struct AutomationPermissionRow: View {
    let appName: String
    let status: PermissionStatus
    let isChecking: Bool
    let onCheck: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appName) automation").font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                Text("Needed by the Import to Library action when importing into \(appName).")
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
            Spacer()
            if isChecking {
                ProgressView().controlSize(.small)
            } else {
                PermissionStatusBadge(status: status)
            }
            switch status {
            case .granted:
                EmptyView()
            case .denied, .restricted:
                Button("Open Settings") { SystemSettings.openPrivacyPane(.automation) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Check Again", action: onCheck)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isChecking)
                    .help("Talks to \(appName) to verify automation access — launches it if it isn't already running.")
            case .unknown:
                Button("Check Access", action: onCheck)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isChecking)
                    .help("Talks to \(appName) to verify automation access — launches it if it isn't already running.")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

private struct PermissionStatusBadge: View {
    let status: PermissionStatus

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var label: String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .unknown: return "Not checked"
        }
    }

    private var color: Color {
        switch status {
        case .granted: return ForelTheme.success
        case .denied, .restricted: return ForelTheme.danger
        case .unknown: return .orange
        }
    }
}

/// Deep links into System Settings' privacy panes. Anchors are undocumented
/// but stable across recent macOS versions.
enum SystemSettings {
    enum PrivacyPane: String {
        case photos = "Privacy_Photos"
        case automation = "Privacy_Automation"
    }

    static func openPrivacyPane(_ pane: PrivacyPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
