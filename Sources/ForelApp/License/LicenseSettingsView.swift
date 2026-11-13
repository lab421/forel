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
            SectionLabel(title: L10n.string("license_status"))
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
                SectionLabel(title: L10n.string("license_licensed_device"))
                GlassCard {
                    SettingsActionRow(
                        title: license.deviceName,
                        subtitle: license.licenseKey,
                        buttonTitle: L10n.string("license_deactivate"),
                        action: { showingDeactivationConfirmation = true }
                    )
                }
            } else {
                SectionLabel(title: L10n.string("license_monthly_usage"))
                MonthlyFileUsageView(onUpgrade: { openURL(ForelLicensing.purchaseURL) })
                SectionLabel(title: L10n.string("license_automate_more_with_pro"))
                ProBenefitsView()
                SectionLabel(title: L10n.string("license_activate_license"))
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        GlassField(placeholder: L10n.string("license_key"), text: $licenseKey)
                            .onSubmit { activate() }

                        HStack {
                            Button(L10n.string("license_buy_forel_pro")) {
                                openURL(ForelLicensing.purchaseURL)
                            }
                            .buttonStyle(.link)

                            Spacer()

                            Button(L10n.string("license_activate"), action: activate)
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
            L10n.string("license_are_you_sure"),
            isPresented: $showingDeactivationConfirmation
        ) {
            Button(L10n.string("license_deactivate"), role: .destructive) {
                Task { await license.deactivate() }
            }
            Button(L10n.string("cancel"), role: .cancel) {}
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
    private var statusTitle: String { license.hasAccess ? L10n.string("forel_pro") : L10n.string("forel_free") }
    private var statusSubtitle: String {
        license.hasAccess
            ? L10n.string("license_unlimited_folders_files_ocr")
            : L10n.string("license_free_forever_2_watched")
    }
}
