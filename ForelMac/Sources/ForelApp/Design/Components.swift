import SwiftUI
import ForelCore

/// Small caps section header, e.g. "WATCHED FOLDERS".
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ForelTheme.secondaryText)
            .padding(.horizontal, 2)
    }
}

/// Pill badge, e.g. "ACTIVE" / "PAUSED".
struct StatusBadge: View {
    let active: Bool

    var body: some View {
        Text(active ? "ACTIVE" : "PAUSED")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(active ? ForelTheme.success : ForelTheme.danger)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill((active ? ForelTheme.success : ForelTheme.danger).opacity(0.16)))
    }
}

/// Translucent rounded surface used to group rows, matching the soft glass
/// cards in the reference design.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
    }
}

/// A title/subtitle row with a trailing switch, e.g. "Watching".
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(ForelTheme.accent)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

/// Small stat tile, e.g. "Rules — 4", used for the activity summary row.
struct StatTile: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(ForelTheme.secondaryText)
                Text(label).font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
            }
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(ForelTheme.primaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ForelTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
    }
}

/// A watched-folder row: icon, name, enabled switch — laid out like the
/// volume-mixer rows in the reference design.
struct QuickFolderRow: View {
    let folder: WatchedFolder
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ForelTheme.accent.opacity(0.18))
                Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(ForelTheme.accent)
            }
            .frame(width: 26, height: 26)

            Text((folder.path as NSString).lastPathComponent)
                .font(.system(size: 13))
                .foregroundStyle(ForelTheme.primaryText)
                .lineLimit(1)

            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(ForelTheme.accent).controlSize(.small)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
    }
}

/// A title row with a trailing segmented picker, used in Settings (e.g. "Theme").
struct PickerRow<Value: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var options: Content

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(ForelTheme.primaryText)
            Spacer()
            Picker("", selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

/// A title/subtitle row with a trailing borderless action button, e.g.
/// "Check for updates now".
struct SettingsActionRow: View {
    let title: String
    let subtitle: String?
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ForelTheme.primaryText)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
                }
            }
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .tint(ForelTheme.accent)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

/// Borderless footer link, e.g. "Settings" / "Quit".
struct FooterLink: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(ForelTheme.secondaryText)
    }
}
