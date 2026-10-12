import SwiftUI
import AppKit
import ForelCore

struct LicenseSettingsView: View {
    @EnvironmentObject var license: ForelLicenseManager
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

            if case .pro = license.state {
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
                SectionLabel(title: "Automate more with Pro")
                ProBenefitsView()
                SectionLabel(title: "Activate License")
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        GlassField(placeholder: "License Key", text: $licenseKey)
                            .onSubmit { activate() }

                        HStack {
                            Button("Buy Forel Pro") {
                                openURL(ForelLicensing.purchaseURL)
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
                Text(lastError)
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
            "Deactivate Forel Pro? Free allows 2 folders with unlimited rules and actions. OCR, scripts, Shortcuts, and media imports require Pro. Your configuration will be kept; rules requiring Pro will stop running.",
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
            if case .pro = license.state {
                licenseKey = ""
            }
        }
    }

    private var statusSymbol: String { license.hasAccess ? "checkmark.seal.fill" : "person.crop.circle" }
    private var statusColor: Color { license.hasAccess ? .green : ForelTheme.secondaryText }
    private var statusTitle: String { license.hasAccess ? "Forel Pro" : "Forel Free" }
    private var statusSubtitle: String {
        license.hasAccess
            ? "Unlimited folders, with OCR and advanced workflows."
            : "Free forever: 2 folders with unlimited rules and actions. No trial."
    }
}
