import AppKit
import SwiftUI
import ForelCore

enum ProUpgradeContext: Identifiable {
    case folders, feature(ProFeature)
    var id: String {
        switch self {
        case .folders: "folders"
        case .feature(let feature): feature.id
        }
    }
    var title: String {
        switch self {
        case .folders: "Automate more folders"
        case .feature(let feature): feature.title
        }
    }
    var message: String {
        switch self {
        case .folders: "Free includes 2 watched folders. With Pro, organize your projects, invoices, and downloads with unlimited folders."
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
            Label("Forel Pro", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(ForelTheme.pro)
            Text(context.title).font(.title2.bold())
            Text(context.message)
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ProBenefitsView()
            Text("Free stays free. Pro is a paid license, with no trial.")
                .font(.caption)
                .foregroundStyle(ForelTheme.secondaryText)
            HStack {
                Button("Continue in Free") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Activate a license") {
                    navigation.selectedCategory = .license
                    dismiss()
                    openSettings()
                }
                Button("View pricing & buy Pro") {
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
            Label("Unlimited watched folders", systemImage: "folder.badge.plus")
            Label("OCR for images and scanned PDFs", systemImage: "text.viewfinder")
            Label("Custom scripts and Apple Shortcuts", systemImage: "terminal")
            Label("Photos, Music, and TV imports", systemImage: "photo.on.rectangle")
        }
        .font(.callout)
        .foregroundStyle(ForelTheme.primaryText)
    }
}
