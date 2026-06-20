import AppKit
import SwiftUI
import ForelCore

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
                subtitle: "Conditions decide which files match; actions decide what happens"
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
        .frame(width: 760, height: 680)
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
                Picker("", selection: kindBinding) {
                    ForEach(Array(RuleSchema.conditionKindGroups.enumerated()), id: \.offset) { _, group in
                        if let title = group.title {
                            Section(title) {
                                ForEach(group.kinds, id: \.self) { kind in
                                    Text(kind.label).tag(kind)
                                }
                            }
                        } else {
                            ForEach(group.kinds, id: \.self) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 160, alignment: .leading)

                Picker("", selection: operatorBinding) {
                    ForEach(condition.kind.validOperators, id: \.self) { op in
                        Text(op.label).tag(op)
                    }
                }
                .labelsHidden()
                .frame(width: 170, alignment: .leading)

                conditionValue
                    .frame(width: 300, alignment: .leading)
                    .frame(minHeight: 32)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus")
                }
                .buttonStyle(IconButtonStyle(role: .destructive))
                .frame(width: 28)
            }

            if let helpText = condition.kind.helpText {
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
            Picker("", selection: unitBinding) {
                ForEach(["days", "weeks", "months", "years"], id: \.self) { unit in
                    Text(unit).tag(unit)
                }
            }
            .labelsHidden()
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
            Picker("", selection: unitBinding) {
                ForEach(["bytes", "KB", "MB", "GB"], id: \.self) { unit in
                    Text(unit).tag(unit)
                }
            }
            .labelsHidden()
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
        Picker("", selection: valueBinding) {
            ForEach(FileKindCatalog.all, id: \.value) { value, label in
                Text(label).tag(value)
            }
        }
        .labelsHidden()
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
            Picker("", selection: kindBinding) {
                ForEach(RuleSchema.actionKinds, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 190)

            actionParams
                .frame(width: 380, alignment: .leading)
                .frame(minHeight: 32)

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
            RenamePatternEditor(pattern: paramBinding(ActionParam.pattern))
        case .addTag, .removeTag:
            TagTokensEditor(tags: tagsBinding, placeholder: action.kind == .addTag ? "Add tag" : "Tag")
        case .setColorLabel:
            ColorLabelPicker(selection: paramBinding(ActionParam.color), allowNone: true)
        case .runScript:
            GlassField(placeholder: "Bash script (file path in $FOREL_FILE)", text: paramBinding(ActionParam.script))
        case .runShortcut:
            ShortcutPicker(selection: paramBinding(ActionParam.shortcutName))
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
                action = Action(id: action.id, ruleId: action.ruleId, kind: newKind, params: .object([:]), position: action.position)
            }
        )
    }

    private func paramBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { action.params[key]?.stringValue ?? "" },
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
            case .moveToFolder:
                moveConflictOptions
            default:
                Text("No options for this action.")
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
        }
    }

    private var moveConflictOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("If a file already exists")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)

            Picker("", selection: paramBinding(ActionParam.onConflict, defaultValue: MoveConflictResolution.rename.rawValue)) {
                ForEach(MoveConflictResolution.allCases, id: \.rawValue) { resolution in
                    Text(resolution.label).tag(resolution.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shortcutOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)

            Picker("", selection: paramBinding(ActionParam.shortcutInputMode, defaultValue: ShortcutInputMode.matchedFile.rawValue)) {
                ForEach(ShortcutInputMode.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                Picker("", selection: shortcutBinding) {
                    ForEach(shortcutOptions, id: \.self) { shortcut in
                        Text(shortcut).tag(shortcut)
                    }
                }
                .labelsHidden()
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
        return "Preview: \(candidate)"
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
