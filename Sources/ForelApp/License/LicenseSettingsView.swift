import SwiftUI
import AppKit
import Lab421Licensing

struct LicenseSettingsView: View {
    @EnvironmentObject var license: LicenseManager
    @Environment(\.openURL) private var openURL
    @State private var licenseKey = ""
    @State private var showingDeactivationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel(title: "License Status")
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ForelTheme.primaryText)
                        Text(statusSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }

            if case .licensed = license.state {
                SectionLabel(title: "Licensed Device")
                GlassCard {
                    SettingsActionRow(
                        title: license.deviceName,
                        subtitle: license.licenseKey,
                        buttonTitle: "Deactivate",
                        action: { showingDeactivationConfirmation = true }
                    )
                }
            } else {
                SectionLabel(title: "Activate License")
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        GlassField(placeholder: "License Key", text: $licenseKey)
                            .onSubmit { activate() }

                        HStack {
                            Button("Buy Forel") {
                                if let url = URL(string: "https://forel.app") {
                                    openURL(url)
                                }
                            }
                            .buttonStyle(.link)

                            Spacer()

                            Button("Activate", action: activate)
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        || license.isWorking
                                )
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                }
            }

            if let lastError = license.lastError {
                Text(lastError.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if license.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 460)
        .confirmationDialog(
            "Deactivate this license? You can activate it on another Mac.",
            isPresented: $showingDeactivationConfirmation
        ) {
            Button("Deactivate", role: .destructive) {
                Task { await license.deactivate() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func activate() {
        Task {
            await license.activate(licenseKey: licenseKey)
            if case .licensed = license.state {
                licenseKey = ""
            }
        }
    }

    private var statusSymbol: String {
        switch license.state {
        case .licensed: "checkmark.seal.fill"
        case .trial, .trialGracePeriod: "clock.fill"
        case .trialUnverified, .trialGracePeriodExpired: "wifi.slash"
        case .trialExpired, .invalid: "exclamationmark.triangle.fill"
        case .bypassed: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch license.state {
        case .licensed, .bypassed: .green
        case .trial, .trialGracePeriod, .trialUnverified: .orange
        case .trialGracePeriodExpired, .trialExpired, .invalid: .red
        }
    }

    private var statusTitle: String {
        license.state.localizedTitle
    }

    private var statusSubtitle: String {
        license.state.localizedSubtitle(appName: ForelLicensing.appName, trialDaysRemaining: license.trialDaysRemaining)
    }
}
