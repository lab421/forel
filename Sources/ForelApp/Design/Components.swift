import SwiftUI
import AppKit
import ForelCore

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = emphasized
    }
}

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
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ForelTheme.surface)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.22))
                }
            )
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
            ForelSwitch(isOn: $isOn)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

struct ForelSwitch: View {
    @Binding var isOn: Bool
    var compact: Bool = false

    private var width: CGFloat { compact ? 42 : 46 }
    private var height: CGFloat { compact ? 23 : 25 }
    private var knobSize: CGFloat { height - 5 }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.16)) {
                isOn.toggle()
            }
        } label: {
            Capsule()
                .fill(isOn ? ForelTheme.accent : ForelTheme.surfaceBorder.opacity(0.9))
                .frame(width: width, height: height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: Color.black.opacity(0.25), radius: 1, y: 1)
                        .padding(.horizontal, 3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enabled")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
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
            ForelSwitch(isOn: $isOn, compact: true)
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

/// Swatch picker for the app's accent colour presets, used in Settings.
struct AccentColorPicker: View {
    @Binding var selection: AccentPreset

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentPreset.allCases) { preset in
                swatch(preset)
            }
            Spacer(minLength: 0)
        }
    }

    private func swatch(_ preset: AccentPreset) -> some View {
        let isSelected = selection == preset
        return Button {
            selection = preset
        } label: {
            Circle()
                .fill(preset.color)
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle().strokeBorder(isSelected ? Color.white : ForelTheme.surfaceBorder, lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }
}

// MARK: - Shared brand mark

/// The small rounded Forel logo tile reused across the panel, settings and
/// main-window headers.
struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let appIcon = AppIcons.appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Color.black)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Standard window header: brand mark + title/subtitle + optional trailing
/// content.
struct ViewHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var systemImage: String?
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(ForelTheme.accent.opacity(0.18))
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ForelTheme.accent)
                }
                .frame(width: 34, height: 34)
            } else {
                BrandMark()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(ForelTheme.primaryText)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
            }
            Spacer()
            trailing
        }
    }
}

extension ViewHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, systemImage: String? = nil) {
        self.init(title: title, subtitle: subtitle, systemImage: systemImage) { EmptyView() }
    }
}

// MARK: - Button styles

/// Filled indigo accent button (primary call to action).
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(ForelTheme.accent.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Capsule())
    }
}

/// Subtle translucent surface button (secondary action).
struct SecondaryButtonStyle: ButtonStyle {
    var role: ButtonRole? = nil

    func makeBody(configuration: Configuration) -> some View {
        let tint = role == .destructive ? ForelTheme.danger : ForelTheme.primaryText
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(ForelTheme.surface))
            .overlay(Capsule().strokeBorder(ForelTheme.surfaceBorder))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// Compact circular icon button.
struct IconButtonStyle: ButtonStyle {
    var role: ButtonRole? = nil

    func makeBody(configuration: Configuration) -> some View {
        let tint = role == .destructive ? ForelTheme.danger : ForelTheme.secondaryText
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(Circle().fill(ForelTheme.surface))
            .overlay(Circle().strokeBorder(ForelTheme.surfaceBorder))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Circle())
    }
}

// MARK: - Inputs

/// Dark glass text field matching the surface styling.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(ForelTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
    }
}

/// A read-only folder path field with a "Choose…" button opening the native
/// macOS Finder directory picker. Used everywhere a folder is selected.
struct FolderField: View {
    let placeholder: String
    @Binding var path: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(ForelTheme.secondaryText)
                Text(path.isEmpty ? placeholder : path)
                    .font(.system(size: 12))
                    .foregroundStyle(path.isEmpty ? ForelTheme.secondaryText : ForelTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))

            Button("Choose…", action: choose).buttonStyle(SecondaryButtonStyle())
        }
    }

    private func choose() {
        let chosen = FolderPicker.choose(startingAt: path)
        if let chosen { path = chosen }
    }
}

/// Native macOS Finder directory picker, shared by every folder selection.
enum FolderPicker {
    @MainActor
    static func choose(startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// Visual picker for the 7 macOS Finder colour labels, shown as colour
/// swatches instead of a free-text field. Binds to the capitalised colour
/// name ("Red", "Blue", …); empty string means "no label".
struct ColorLabelPicker: View {
    @Binding var selection: String
    var allowNone: Bool = true

    /// Approximation of the macOS Finder label colours.
    static let colors: [(name: String, color: Color)] = [
        ("Red", .red),
        ("Orange", .orange),
        ("Yellow", .yellow),
        ("Green", .green),
        ("Blue", .blue),
        ("Purple", .purple),
        ("Gray", .gray),
    ]

    var body: some View {
        HStack(spacing: 8) {
            if allowNone {
                swatch(name: "", color: nil)
            }
            ForEach(Self.colors, id: \.name) { item in
                swatch(name: item.name, color: item.color)
            }
            Spacer(minLength: 0)
        }
    }

    private func swatch(name: String, color: Color?) -> some View {
        let isSelected = selection.lowercased() == name.lowercased()
        return Button {
            selection = name
        } label: {
            Circle()
                .fill(color ?? ForelTheme.surface)
                .frame(width: 22, height: 22)
                .overlay {
                    if color == nil {
                        Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                    } else if isSelected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle().strokeBorder(isSelected ? Color.white : ForelTheme.surfaceBorder, lineWidth: isSelected ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .help(name.isEmpty ? "No label" : name)
    }
}
