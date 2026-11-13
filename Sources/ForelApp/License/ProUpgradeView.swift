import AppKit
import SwiftUI
import ForelCore

enum ProUpgradeContext: Identifiable {
    case folders, monthlyFiles, feature(ProFeature)
    var id: String {
        switch self {
        case .folders: "folders"
        case .monthlyFiles: "monthly-files"
        case .feature(let feature): feature.id
        }
    }
    var title: String {
        switch self {
        case .folders: L10n.string("pro_automate_more_folders")
        case .monthlyFiles: L10n.string("pro_keep_processing_with_pro")
        case .feature(let feature): feature.title
        }
    }
    var message: String {
        switch self {
        case .folders: L10n.string("pro_free_includes_2_watched")
        case .monthlyFiles: L10n.string("pro_free_includes_300_processed")
        case .feature(let feature): feature.benefit
        }
    }
}

struct ProUpgradeView: View {
    let context: ProUpgradeContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.string("forel_pro"), systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(ForelTheme.pro)
            Text(context.title).font(.title2.bold())
            Text(context.message)
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ProBenefitsView()
            Text(L10n.string("pro_free_stays_free_pro"))
                .font(.caption)
                .foregroundStyle(ForelTheme.secondaryText)
            HStack {
                Button(L10n.string("pro_continue_in_free")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("pro_activate_a_license")) {
                    navigation.selectedCategory = .license
                    dismiss()
                    openSettings()
                }
                Button(L10n.string("pro_view_pricing_buy_pro")) {
                    openURL(ForelLicensing.purchaseURL)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
        .foregroundStyle(ForelTheme.primaryText)
        .background(ForelTheme.background)
    }
}

struct ProBenefitsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(L10n.string("pro_unlimited_watched_folders"), systemImage: "folder.badge.plus")
            Label(L10n.string("pro_unlimited_files_processed"), systemImage: "doc.on.doc")
            Label(L10n.string("pro_ocr_images_scanned_pdfs"), systemImage: "text.viewfinder")
            Label(L10n.string("pro_photos_music_tv_imports"), systemImage: "photo.on.rectangle")
        }
        .font(.callout)
        .foregroundStyle(ForelTheme.primaryText)
    }
}
