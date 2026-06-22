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

import AppKit
import SwiftUI
import ForelCore
#if canImport(Photos)
import Photos
#endif

struct RuleEditorView: View {
    @State private var rule: Rule
    @EnvironmentObject private var model: AppModel
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    init(rule: Rule, onSave: @escaping (Rule) -> Void, onCancel: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewHeader(
                title: rule.name.isEmpty ? "New Rule" : "Edit Rule",
                subtitle: "Conditions decide which files match; actions decide what happens",
                systemImage: "slider.horizontal.3"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel(title: "Basics")
                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            GlassField(placeholder: "Rule name", text: $rule.name)
                            ScopeEditor(depth: $rule.recursionDepth)

                            Picker("", selection: $rule.conditionMatch) {
                                Text("Match all conditions").tag(ConditionMatch.all)
                                Text("Match any condition").tag(ConditionMatch.any)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        .padding(18)
                    }

                    HStack {
                        SectionLabel(title: "Conditions")
                        Spacer()
                        Button {
                            rule.conditions.append(Condition(ruleId: rule.id, kind: .name, operator: .contains, value: ""))
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            if rule.conditions.isEmpty {
                                placeholder("No conditions — this rule matches every file in scope.")
                            }
                            ForEach($rule.conditions, id: \.id) { $condition in
                                ConditionRow(condition: $condition) {
                                    rule.conditions.removeAll { $0.id == condition.id }
                                }
                            }
                        }
                        .padding(18)
                    }

                    HStack {
                        SectionLabel(title: "Actions")
                        Spacer()
                        Button {
                            rule.actions.append(Action(ruleId: rule.id, kind: .moveToFolder, params: .object(["destination": .string("")]), position: Int64(rule.actions.count)))
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            if rule.actions.isEmpty {
                                placeholder("No actions yet — add at least one to make this rule do something.")
                            }
                            ForEach($rule.actions, id: \.id) { $action in
                                ActionRow(action: $action) {
                                    rule.actions.removeAll { $0.id == action.id }
                                }
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .scrollIndicators(.never)

            Divider().overlay(ForelTheme.divider)

            HStack {
                Toggle("Enabled", isOn: $rule.enabled)
                    .toggleStyle(.switch)
                    .tint(ForelTheme.accent)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(SecondaryButtonStyle())
                Button("Save") { onSave(rule) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty || hasInvalidRegexCondition)
            }
        }
        .padding(22)
        .frame(width: 880, height: 680)
        .background(ForelTheme.background)
        .background(WindowActivationBridge(showsDockIcon: model.showDockIcon))
    }

    /// A rule with an unparsable regex would just silently never match at
    /// run time; block saving it instead of letting that ship invisibly.
    private var hasInvalidRegexCondition: Bool {
        rule.conditions.contains { condition in
            guard condition.operator == .matchesRegex, !condition.value.isEmpty else { return false }
            return (try? NSRegularExpression(pattern: condition.value)) == nil
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(ForelTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct ScopeEditor: View {
    @Binding var depth: Int64?
    @State private var lastExplicitDepth: Int64 = 1

    init(depth: Binding<Int64?>) {
        _depth = depth
        let initialDepth = depth.wrappedValue ?? 1
        _lastExplicitDepth = State(initialValue: max(1, initialDepth))
    }

    private var modeBinding: Binding<Int> {
        Binding(
            get: { depth == 0 ? 0 : 1 },
            set: { mode in
                if mode == 0 {
                    if let depth, depth > 0 {
                        lastExplicitDepth = depth
                    }
                    depth = 0
                } else if depth == 0 {
                    depth = lastExplicitDepth
                }
            }
        )
    }

    private var allLevelsBinding: Binding<Bool> {
        Binding(
            get: { depth == nil },
            set: { allLevels in
                if allLevels {
                    if let depth, depth > 0 {
                        lastExplicitDepth = depth
                    }
                    depth = nil
                } else {
                    depth = lastExplicitDepth
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Scope").font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                Spacer()
                Picker("", selection: modeBinding) {
                    Text("Current folder").tag(0)
                    Text("Subfolders").tag(1)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            if depth != 0 {
                HStack(spacing: 10) {
                    Text("Depth").font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                    GlassField(placeholder: "1", text: depthTextBinding)
                        .frame(width: 72)
                        .disabled(depth == nil)
                    Toggle("All levels", isOn: allLevelsBinding)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(ForelTheme.primaryText)
                    Text(scopeSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                    Spacer()
                }

                if depth == nil {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                        Text("All levels can slow execution in folders with many files. Use with caution.")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 52)
                }
            }
        }
    }

    private var depthTextBinding: Binding<String> {
        Binding(
            get: {
                if let depth {
                    return "\(max(1, depth))"
                }
                return "\(lastExplicitDepth)"
            },
            set: { value in
                let filtered = value.filter(\.isNumber)
                lastExplicitDepth = max(1, Int64(filtered) ?? 1)
                depth = lastExplicitDepth
            }
        )
    }

    private var scopeSummary: String {
        guard let depth else { return "All subfolder levels" }
        let safeDepth = max(1, depth)
        return "\(safeDepth) subfolder level\(safeDepth == 1 ? "" : "s")"
    }
}

private struct ConditionRow: View {
    @Binding var condition: Condition
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                ConditionKindMenu(selection: kindBinding)
                .frame(minWidth: 140, alignment: .leading)

                ConditionOperatorMenu(selection: operatorBinding, operators: condition.kind.validOperators)
                .frame(minWidth: 140, alignment: .leading)

                conditionValue
                    .frame(minWidth: 200, alignment: .leading)
                    .frame(minHeight: 32)
                    .layoutPriority(1)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus")
                }
                .buttonStyle(IconButtonStyle(role: .destructive))
                .frame(width: 28)
            }

            if let helpText = rowHelpText {
                Text(helpText)
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.secondaryText)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder private var conditionValue: some View {
        switch RuleSchema.valueKind(for: condition.kind, operator: condition.operator) {
        case .colorLabel:
            ColorLabelPicker(selection: $condition.value, allowNone: false)
        case .fileKind:
            KindValuePicker(value: $condition.value)
        case .appPicker:
            AppPickerField(value: $condition.value)
        case .size:
            SizeValueEditor(value: $condition.value)
        case .relativeDate:
            RelativeDateValueEditor(value: $condition.value)
        case .absoluteDate:
            AbsoluteDateValueEditor(value: $condition.value)
        case .regex:
            RegexValueEditor(value: $condition.value)
        case .text:
            GlassField(placeholder: "Value", text: $condition.value)
        }
    }

    private var rowHelpText: String? {
        if condition.kind == .kind, condition.value == "archive" {
            return "Archive matches compressed formats such as ZIP, TAR, GZ, 7Z, RAR, XZ, ZST, TGZ, TBZ, and CAB."
        }
        return condition.kind.helpText
    }

    private var kindBinding: Binding<ConditionKind> {
        Binding(
            get: { condition.kind },
            set: { newKind in
                condition.kind = newKind
                if !newKind.validOperators.contains(condition.operator) {
                    condition.operator = newKind.defaultOperator
                }
                condition.value = defaultValue(for: newKind, operator_: condition.operator)
            }
        )
    }

    private var operatorBinding: Binding<Operator> {
        Binding(
            get: { condition.operator },
            set: { newOperator in
                let oldOperator = condition.operator
                condition.operator = newOperator
                if condition.kind.baseValueKind == .absoluteDate {
                    let changedValueFormat = oldOperator.usesRelativeDateValue != newOperator.usesRelativeDateValue
                    if changedValueFormat || condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                        condition.value = newOperator.usesRelativeDateValue ? "7 days" : DateValueFormatter.string(from: Date())
                    }
                }
                if condition.kind == .sizeBytes, condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                    condition.value = "0 MB"
                }
            }
        )
    }

    private func defaultValue(for kind: ConditionKind, operator_: Operator) -> String {
        switch kind.baseValueKind {
        case .fileKind: return "image"
        case .size: return "0 MB"
        case .absoluteDate:
            return operator_.usesRelativeDateValue ? "7 days" : DateValueFormatter.string(from: Date())
        default: return ""
        }
    }
}

private struct ConditionKindMenu: View {
    @Binding var selection: ConditionKind

    var body: some View {
        RuleSelectMenu(title: selection.label) {
            ForEach(Array(RuleSchema.conditionKindGroups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Section(title) {
                        ForEach(group.kinds, id: \.self) { kind in
                            Button {
                                selection = kind
                            } label: {
                                HStack {
                                    Image(systemName: kind.iconSystemName)
                                        .frame(width: 16)
                                    Text(kind.label)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(group.kinds, id: \.self) { kind in
                        Button {
                            selection = kind
                        } label: {
                            HStack {
                                Image(systemName: kind.iconSystemName)
                                    .frame(width: 16)
                                Text(kind.label)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ConditionOperatorMenu: View {
    @Binding var selection: Operator
    let operators: [Operator]

    var body: some View {
        RuleSelectMenu(title: selection.label) {
            ForEach(operators, id: \.self) { op in
                Button(op.label) { selection = op }
            }
        }
    }
}

private struct ActionKindMenu: View {
    @Binding var selection: ActionKind

    var body: some View {
        RuleSelectMenu(title: selection.label) {
            ForEach(Array(RuleSchema.actionKindGroups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Section(title) {
                        ForEach(group.kinds, id: \.self) { kind in
                            Button {
                                selection = kind
                            } label: {
                                HStack {
                                    Image(systemName: kind.iconSystemName)
                                        .frame(width: 16)
                                    Text(kind.label)
                                }
                            }
                        }
                    }
                } else {
                    ForEach(group.kinds, id: \.self) { kind in
                        Button {
                            selection = kind
                        } label: {
                            HStack {
                                Image(systemName: kind.iconSystemName)
                                    .frame(width: 16)
                                Text(kind.label)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct StringSelectMenu: View {
    @Binding var selection: String
    let options: [String]
    let label: (String) -> String

    init(selection: Binding<String>, options: [String], label: @escaping (String) -> String = { $0 }) {
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        RuleSelectMenu(title: label(selection)) {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { selection = option }
            }
        }
    }
}

private struct RuleSelectMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
        }
        .buttonStyle(.plain)
    }
}

/// Plain text field for a regex condition, but validated as you type: an
/// invalid pattern would otherwise just make the condition silently never
/// match at run time, with no indication why. Catching it here means the
/// engine itself can stay tolerant (a regex error is still just "no match",
/// not a crash) while the person writing the rule actually finds out.
private struct RegexValueEditor: View {
    @Binding var value: String

    private var errorMessage: String? {
        guard !value.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: value)
            return nil
        } catch {
            return "Invalid regular expression"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassField(placeholder: "Regex pattern", text: $value)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(ForelTheme.danger)
            }
        }
    }
}

private struct AbsoluteDateValueEditor: View {
    @Binding var value: String

    var body: some View {
        DatePicker("", selection: dateBinding, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(width: 180, alignment: .leading)
            .onAppear {
                if DateValueFormatter.date(from: value) == nil {
                    value = DateValueFormatter.string(from: Date())
                }
            }
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { DateValueFormatter.date(from: value) ?? Date() },
            set: { value = DateValueFormatter.string(from: $0) }
        )
    }
}

private struct RelativeDateValueEditor: View {
    @Binding var value: String

    var body: some View {
        HStack(spacing: 8) {
            GlassField(placeholder: "7", text: numberBinding)
                .frame(width: 72)
            StringSelectMenu(selection: unitBinding, options: ["days", "weeks", "months", "years"])
            .frame(width: 120)
            Spacer(minLength: 0)
        }
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: { parts.number },
            set: { value = "\($0.filter(\.isNumber)) \(parts.unit)" }
        )
    }

    private var unitBinding: Binding<String> {
        Binding(
            get: { parts.unit },
            set: { value = "\(parts.number) \($0)" }
        )
    }

    private var parts: (number: String, unit: String) {
        let pieces = value.split(separator: " ", maxSplits: 1).map(String.init)
        let number = pieces.first?.filter(\.isNumber)
        let unit = pieces.count > 1 ? pieces[1] : "days"
        return ((number?.isEmpty == false ? number! : "7"), ["days", "weeks", "months", "years"].contains(unit) ? unit : "days")
    }
}

private struct SizeValueEditor: View {
    @Binding var value: String

    var body: some View {
        HStack(spacing: 8) {
            GlassField(placeholder: "0", text: numberBinding)
                .frame(width: 90)
            StringSelectMenu(selection: unitBinding, options: ["bytes", "KB", "MB", "GB"])
            .frame(width: 110)
            Spacer(minLength: 0)
        }
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: { parts.number },
            set: { value = "\($0.filter { $0.isNumber || $0 == "." }) \(parts.unit)" }
        )
    }

    private var unitBinding: Binding<String> {
        Binding(
            get: { parts.unit },
            set: { value = "\(parts.number) \($0)" }
        )
    }

    private var parts: (number: String, unit: String) {
        let pieces = value.split(separator: " ", maxSplits: 1).map(String.init)
        let number = pieces.first?.filter { $0.isNumber || $0 == "." }
        let rawUnit = pieces.count > 1 ? pieces[1] : "MB"
        let unit = ["bytes", "KB", "MB", "GB"].contains(rawUnit) ? rawUnit : "MB"
        return ((number?.isEmpty == false ? number! : "0"), unit)
    }
}

/// Text field showing the matched app's real icon (same idea as `FolderField`),
/// with a "Choose…" button that opens a Finder-style picker scoped to
/// `/Applications`. Stays a plain text field underneath so a missing or
/// differently named quarantine agent can still be typed manually.
private struct AppPickerField: View {
    @Binding var value: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                iconView
                TextField("App name", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(ForelTheme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))

            Button("Choose…", action: choose).buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder private var iconView: some View {
        if let path = InstalledApps.path(forName: value) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 12))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(width: 16, height: 16)
        }
    }

    private func choose() {
        if let app = InstalledApps.pickFromFinder() {
            value = app.name
        }
    }
}

private struct KindValuePicker: View {
    @Binding var value: String

    var body: some View {
        StringSelectMenu(
            selection: valueBinding,
            options: FileKindCatalog.all.map(\.value),
            label: { value in FileKindCatalog.all.first { $0.value == value }?.label ?? value }
        )
        .frame(width: 180, alignment: .leading)
    }

    private var valueBinding: Binding<String> {
        Binding(
            get: {
                FileKindCatalog.all.contains { $0.value == value } ? value : "image"
            },
            set: { value = $0 }
        )
    }
}

private struct ActionRow: View {
    @Binding var action: Action
    let onDelete: () -> Void
    @State private var showingOptions = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ActionKindMenu(selection: kindBinding)
            .frame(minWidth: 160, alignment: .leading)

            actionParams
                .frame(minWidth: 200, alignment: .leading)
                .frame(minHeight: 32)
                .layoutPriority(1)

            if action.kind.hasOptions {
                Button {
                    showingOptions.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(IconButtonStyle())
                .help("Action options")
                .frame(width: 28)
                .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                    ActionOptionsView(action: $action)
                        .padding(14)
                        .frame(width: 280)
                }
            } else {
                Spacer().frame(width: 28)
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle(role: .destructive))
            .frame(width: 28)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ForelTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
    }

    @ViewBuilder private var actionParams: some View {
        switch action.kind {
        case .moveToFolder, .copyToFolder:
            FolderField(placeholder: "Destination folder", path: paramBinding(ActionParam.destination))
        case .rename:
            RenamePatternEditor(pattern: paramBinding(ActionParam.pattern), cleanFileName: action.params[ActionParam.cleanFileName]?.boolValue == true)
        case .addTag, .removeTag:
            TagTokensEditor(tags: tagsBinding, placeholder: action.kind == .addTag ? "Add tag" : "Tag")
        case .setColorLabel:
            ColorLabelPicker(selection: paramBinding(ActionParam.color), allowNone: true)
        case .runScript:
            GlassField(placeholder: "Bash script (file path in $FOREL_FILE)", text: paramBinding(ActionParam.script))
        case .runShortcut:
            ShortcutPicker(selection: paramBinding(ActionParam.shortcutName))
        case .importToLibrary:
            let libTypeBinding = paramBinding(ActionParam.libraryType, defaultValue: LibraryType.music.rawValue)
            let libType = LibraryType(rawValue: libTypeBinding.wrappedValue)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Library:")
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .frame(width: 52, alignment: .trailing)
                    LibraryTypePicker(selection: libTypeBinding)
                }
                if libType == .music || libType == .tv {
                    let app = libType == .music ? "Music" : "TV"
                    HStack(spacing: 6) {
                        Text("Playlist:")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                        PlaylistPicker(selection: paramBinding(ActionParam.targetPlaylist), app: app)
                            .id(app)
                    }
                } else if libType == .photos {
                    HStack(spacing: 6) {
                        Text("Album:")
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                        AlbumPicker(selection: paramBinding(ActionParam.targetPlaylist))
                    }
                }
            }
        case .uncompress:
            Text("ZIP archives only")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(minHeight: 32, alignment: .center)
        case .moveToTrash, .delete:
            Text("No parameters")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(minHeight: 32, alignment: .center)
        }
    }

    private var kindBinding: Binding<ActionKind> {
        Binding(
            get: { action.kind },
            set: { newKind in
                var params: [String: JSONValue] = [:]
                if newKind == .importToLibrary {
                    params[ActionParam.libraryType] = .string(LibraryType.music.rawValue)
                }
                action = Action(id: action.id, ruleId: action.ruleId, kind: newKind, params: .object(params), position: action.position)
            }
        )
    }

    private func paramBinding(_ key: String, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: { action.params[key]?.stringValue ?? defaultValue },
            set: { newValue in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { dict = existing }
                dict[key] = .string(newValue)
                action.params = .object(dict)
            }
        )
    }

    private var tagsBinding: Binding<[String]> {
        Binding(
            get: {
                if let tags = action.params[ActionParam.tags]?.arrayValue {
                    return tags.compactMap(\.stringValue)
                }
                // Legacy single-tag param from older saved rules.
                if let tag = action.params["tag"]?.stringValue, !tag.trimmingCharacters(in: .whitespaces).isEmpty {
                    return [tag]
                }
                return []
            },
            set: { newTags in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params {
                    dict = existing
                }
                let normalized = newTags.map { JSONValue.string($0) }
                dict[ActionParam.tags] = .array(normalized)
                dict.removeValue(forKey: "tag")
                action.params = .object(dict)
            }
        )
    }
}

private struct ActionOptionsView: View {
    @Binding var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ForelTheme.primaryText)

            switch action.kind {
            case .runShortcut:
                shortcutOptions
            case .moveToFolder, .copyToFolder, .importToLibrary, .uncompress:
                conflictResolutionOptions
            case .rename:
                renameOptions
            default:
                Text("No options for this action.")
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
        }
    }

    private var conflictResolutionOptions: some View {
        let defaultResolution = action.kind == .importToLibrary ? MoveConflictResolution.skip.rawValue : MoveConflictResolution.rename.rawValue
        let options = action.kind == .importToLibrary
            ? MoveConflictResolution.allCases.filter { $0 != .rename }.map(\.rawValue)
            : MoveConflictResolution.allCases.map(\.rawValue)
        return VStack(alignment: .leading, spacing: 6) {
            Text("If a file already exists")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)

            StringSelectMenu(
                selection: paramBinding(ActionParam.onConflict, defaultValue: defaultResolution),
                options: options,
                label: { value in MoveConflictResolution(rawValue: value)?.label ?? value }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shortcutOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)

            StringSelectMenu(
                selection: paramBinding(ActionParam.shortcutInputMode, defaultValue: ShortcutInputMode.matchedFile.rawValue),
                options: ShortcutInputMode.allCases.map(\.rawValue),
                label: { value in ShortcutInputMode(rawValue: value)?.label ?? value }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var renameOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: cleanNameBinding) {
                Text("Clean file name")
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var cleanNameBinding: Binding<Bool> {
        Binding(
            get: { action.params[ActionParam.cleanFileName]?.boolValue == true },
            set: { newValue in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { dict = existing }
                dict[ActionParam.cleanFileName] = .bool(newValue)
                action.params = .object(dict)
            }
        )
    }

    private func paramBinding(_ key: String, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: { action.params[key]?.stringValue ?? defaultValue },
            set: { newValue in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { dict = existing }
                dict[key] = .string(newValue)
                action.params = .object(dict)
            }
        )
    }
}

private struct ShortcutPicker: View {
    @Binding var selection: String
    @State private var shortcuts: [String] = []
    @State private var isLoading = false

    var body: some View {
        HStack(spacing: 8) {
            if shortcuts.isEmpty {
                GlassField(placeholder: isLoading ? "Loading shortcuts..." : "Shortcut name", text: $selection)
            } else {
                StringSelectMenu(selection: shortcutBinding, options: shortcutOptions)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: loadShortcuts) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh shortcuts")
        }
        .task {
            if shortcuts.isEmpty {
                loadShortcuts()
            }
        }
    }

    private var shortcutOptions: [String] {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !shortcuts.contains(trimmed) else { return shortcuts }
        return [trimmed] + shortcuts
    }

    private var shortcutBinding: Binding<String> {
        Binding(
            get: {
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                return shortcuts.first ?? ""
            },
            set: { selection = $0 }
        )
    }

    private func loadShortcuts() {
        isLoading = true
        DispatchQueue.global(qos: .utility).async {
            let names = ShortcutCatalog.availableShortcutNames()
            DispatchQueue.main.async {
                shortcuts = names
                if selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let first = names.first {
                    selection = first
                }
                isLoading = false
            }
        }
    }
}

private struct LibraryTypePicker: View {
    @Binding var selection: String

    var body: some View {
        StringSelectMenu(
            selection: $selection,
            options: LibraryType.allCases.map(\.rawValue),
            label: { value in LibraryType(rawValue: value)?.label ?? value }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaylistPicker: View {
    @Binding var selection: String
    let app: String
    @State private var items: [String] = [""]
    @State private var isLoading = true

    var body: some View {
        HStack(spacing: 4) {
            StringSelectMenu(
                selection: $selection,
                options: items,
                label: { $0.isEmpty ? "None" : $0 }
            )
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    private func load() async {
        let script = """
        tell application "\(app)"
            set playlistNames to name of every user playlist
            set AppleScript's text item delimiters to linefeed
            return playlistNames as string
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if task.terminationStatus == 0 && !output.isEmpty {
                let names = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                await MainActor.run { items = [""] + names }
            }
        } catch {}
        await MainActor.run { isLoading = false }
    }
}

private struct AlbumPicker: View {
    @Binding var selection: String
    @State private var items: [String] = [""]
    @State private var isLoading = true

    var body: some View {
        HStack(spacing: 4) {
            StringSelectMenu(
                selection: $selection,
                options: items,
                label: { $0.isEmpty ? "None" : $0 }
            )
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    private func load() async {
        await MainActor.run {
            #if canImport(Photos)
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                isLoading = false
                return
            }
            let options = PHFetchOptions()
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
            var names: [String] = []
            collections.enumerateObjects { collection, _, _ in
                names.append(collection.localizedTitle ?? "Untitled")
            }
            items = [""] + names.sorted()
            #endif
            isLoading = false
        }
    }
}

private struct TagTokensEditor: View {
    @Binding var tags: [String]
    let placeholder: String
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                        tagChip(tag)
                    }
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(ForelTheme.primaryText)
                        .focused($isFocused)
                        .frame(minWidth: 90)
                        .onSubmit(addDraftTag)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))

            Button(action: addDraftTag) {
                Image(systemName: "return")
            }
            .buttonStyle(IconButtonStyle())
            .help("Add tag")
        }
        .onAppear { isFocused = true }
    }

    private func addDraftTag() {
        let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !tags.contains(cleaned) {
            tags.append(cleaned)
        }
        draft = ""
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 5) {
            Text(tag)
                .font(.system(size: 12, weight: .medium))
            Button {
                removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ForelTheme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(ForelTheme.accent.opacity(0.18)))
        .overlay(Capsule().strokeBorder(ForelTheme.accent.opacity(0.35)))
        .foregroundStyle(ForelTheme.primaryText)
    }
}

private struct RenamePatternEditor: View {
    @Binding var pattern: String
    let cleanFileName: Bool

    private let tokens: [(placeholder: String, label: String)] = [
        ("{name}", "name"),
        ("{extension}", "extension"),
        ("{date_modified}", "date modified"),
        ("{date_created}", "date created"),
        ("{current_date}", "current date"),
        ("{size}", "size"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassField(placeholder: "Pattern, e.g. {name}-{current_date}.{extension}", text: $pattern)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tokens, id: \.placeholder) { token in
                        tokenButton(token)
                    }
                    Spacer(minLength: 0)
                }
            }

            Text(preview)
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
        }
    }

    private var preview: String {
        let candidate = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return "Preview: " }
        if candidate.contains("/") {
            return "⚠️ Pattern contains '/' which is not allowed in filenames"
        }
        let previewName = candidate
            .replacingOccurrences(of: "{name}", with: "file")
            .replacingOccurrences(of: "{extension}", with: "txt")
            .replacingOccurrences(of: "{current_date}", with: dateString())
        let displayName = cleanFileName ? ActionExecutor.cleanFileName(previewName) : previewName
        if displayName == "." || displayName == ".." {
            return "⚠️ Pattern resolves to '\(displayName)' which is not a valid filename"
        }
        if displayName.utf8.count > 255 {
            return "⚠️ Pattern resolves to a filename longer than 255 characters"
        }
        if let last = displayName.last, last == "." || last == " " {
            return "⚠️ Pattern resolves to '\(displayName)' — trailing '.' or space is not supported"
        }
        return "Preview: \(displayName)"
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func tokenButton(_ token: (placeholder: String, label: String)) -> some View {
        let isActive = pattern.contains(token.placeholder)
        return Button {
            insert(token.placeholder)
        } label: {
            Text(token.label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(isActive ? ForelTheme.accent.opacity(0.22) : ForelTheme.surface))
                .overlay(Capsule().strokeBorder(isActive ? ForelTheme.accent : ForelTheme.surfaceBorder))
                .foregroundStyle(isActive ? ForelTheme.accent : ForelTheme.secondaryText)
        }
        .buttonStyle(.plain)
    }

    private func insert(_ token: String) {
        guard !pattern.contains(token) else { return }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            pattern = token
        } else {
            pattern = "\(trimmed)\(trimmed.hasSuffix("-") || trimmed.hasSuffix(".") ? "" : "-")\(token)"
        }
    }
}

private enum DateValueFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(from value: String) -> Date? {
        formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
