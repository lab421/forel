import SwiftUI
import ForelCore

struct RuleEditorView: View {
    @State private var rule: Rule
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
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 760, height: 680)
        .background(ForelTheme.background)
        .background(WindowActivationBridge())
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
        HStack(alignment: .center, spacing: 12) {
            Picker("", selection: kindBinding) {
                ForEach(ConditionEditorLabels.kinds, id: \.0) { kind, label in
                    Text(label).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 160)

            Picker("", selection: operatorBinding) {
                ForEach(ConditionEditorLabels.operators(for: condition.kind), id: \.0) { op, label in
                    Text(label).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            conditionValue
                .frame(width: 300, alignment: .leading)
                .frame(minHeight: 32)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus")
            }
            .buttonStyle(IconButtonStyle(role: .destructive))
            .frame(width: 28)
        }
    }

    @ViewBuilder private var conditionValue: some View {
        if condition.kind == .colorLabel {
            ColorLabelPicker(selection: $condition.value, allowNone: false)
        } else if condition.kind == .kind {
            KindValuePicker(value: $condition.value)
        } else if condition.kind == .sizeBytes {
            SizeValueEditor(value: $condition.value)
        } else if condition.kind.isDateKind && condition.operator.isRelativeDateOperator {
            RelativeDateValueEditor(value: $condition.value)
        } else if condition.kind.isDateKind {
            AbsoluteDateValueEditor(value: $condition.value)
        } else {
            GlassField(placeholder: "Value", text: $condition.value)
        }
    }

    private var kindBinding: Binding<ConditionKind> {
        Binding(
            get: { condition.kind },
            set: { newKind in
                condition.kind = newKind
                let operators = ConditionEditorLabels.operators(for: newKind).map(\.0)
                if !operators.contains(condition.operator) {
                    condition.operator = ConditionEditorLabels.defaultOperator(for: newKind)
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
                if condition.kind.isDateKind {
                    let changedValueFormat = oldOperator.isRelativeDateOperator != newOperator.isRelativeDateOperator
                    if changedValueFormat || condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                        condition.value = newOperator.isRelativeDateOperator ? "7 days" : DateValueFormatter.string(from: Date())
                    }
                }
                if condition.kind == .sizeBytes, condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                    condition.value = "0 bytes"
                }
            }
        )
    }

    private func defaultValue(for kind: ConditionKind, operator_: Operator) -> String {
        if kind == .kind { return "image" }
        if kind == .sizeBytes { return "0 bytes" }
        if kind.isDateKind {
            return operator_.isRelativeDateOperator ? "7 days" : DateValueFormatter.string(from: Date())
        }
        return ""
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
        let rawUnit = pieces.count > 1 ? pieces[1] : "bytes"
        let unit = ["bytes", "KB", "MB", "GB"].contains(rawUnit) ? rawUnit : "bytes"
        return ((number?.isEmpty == false ? number! : "0"), unit)
    }
}

private struct KindValuePicker: View {
    @Binding var value: String

    var body: some View {
        Picker("", selection: valueBinding) {
            ForEach(ConditionEditorLabels.fileKinds, id: \.0) { value, label in
                Text(label).tag(value)
            }
        }
        .labelsHidden()
        .frame(width: 180, alignment: .leading)
    }

    private var valueBinding: Binding<String> {
        Binding(
            get: {
                ConditionEditorLabels.fileKinds.contains { $0.0 == value } ? value : "image"
            },
            set: { value = $0 }
        )
    }
}

private struct ActionRow: View {
    @Binding var action: Action
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("", selection: kindBinding) {
                ForEach(ConditionEditorLabels.actionKinds, id: \.0) { kind, label in
                    Text(label).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 190)

            actionParams
                .frame(width: 420, alignment: .leading)
                .frame(minHeight: 32)

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
            FolderField(placeholder: "Destination folder", path: paramBinding("destination"))
        case .rename:
            RenamePatternEditor(pattern: paramBinding("pattern"))
        case .addTag, .removeTag:
            TagTokensEditor(tags: tagsBinding, placeholder: action.kind == .addTag ? "Add tag" : "Tag")
        case .setColorLabel:
            ColorLabelPicker(selection: paramBinding("color"), allowNone: true)
        case .runScript:
            GlassField(placeholder: "Bash script (file path in $FOREL_FILE)", text: paramBinding("script"))
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
                if let tags = action.params["tags"]?.arrayValue {
                    return tags.compactMap(\.stringValue)
                }
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
                dict["tags"] = .array(normalized)
                dict.removeValue(forKey: "tag")
                action.params = .object(dict)
            }
        )
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

enum ConditionEditorLabels {
    static let kinds: [(ConditionKind, String)] = [
        (.name, "Name"), (.extension_, "Extension"), (.kind, "Kind"), (.sizeBytes, "Size"),
        (.tags, "Tags"), (.colorLabel, "Color label"), (.contents, "Contents"),
        (.createdAt, "Date created"), (.dateModified, "Date modified"), (.dateAdded, "Date added"),
    ]

    private static let allOperators: [(Operator, String)] = [
        (.is, "is"), (.isNot, "is not"), (.contains, "contains"), (.doesNotContain, "does not contain"),
        (.startsWith, "starts with"), (.endsWith, "ends with"), (.matchesRegex, "matches regex"),
        (.greaterThan, "greater than"), (.lessThan, "less than"), (.before, "is before"),
        (.after, "is after"), (.olderThan, "is older than"), (.withinLast, "is within the last"),
    ]

    static func operators(for kind: ConditionKind) -> [(Operator, String)] {
        switch kind {
        case .createdAt, .dateModified, .dateAdded:
            return allOperators.filter { [.before, .after, .olderThan, .withinLast].contains($0.0) }
        case .sizeBytes:
            return allOperators.filter { [.is, .isNot, .greaterThan, .lessThan].contains($0.0) }
        case .kind:
            return allOperators.filter { [.is, .isNot].contains($0.0) }
        case .colorLabel:
            return allOperators.filter { [.is, .isNot].contains($0.0) }
        default:
            return allOperators.filter { [.is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .matchesRegex].contains($0.0) }
        }
    }

    static func defaultOperator(for kind: ConditionKind) -> Operator {
        kind.isDateKind ? .before : operators(for: kind).first?.0 ?? .is
    }

    static let fileKinds: [(String, String)] = [
        ("image", "Image"),
        ("movie", "Movie"),
        ("music", "Music"),
        ("pdf", "PDF"),
        ("text", "Text"),
        ("document", "Document"),
        ("presentation", "Presentation"),
        ("archive", "Archive"),
        ("disk_image", "Disk Image"),
        ("folder", "Folder"),
        ("application", "Application"),
    ]

    static let actionKinds: [(ActionKind, String)] = [
        (.moveToFolder, "Move to folder"), (.copyToFolder, "Copy to folder"), (.rename, "Rename"),
        (.moveToTrash, "Move to Trash"), (.delete, "Delete"), (.addTag, "Add tag"),
        (.removeTag, "Remove tag"), (.setColorLabel, "Set color label"), (.runScript, "Run script"),
    ]
}

private extension ConditionKind {
    var isDateKind: Bool {
        self == .createdAt || self == .dateModified || self == .dateAdded
    }
}

private extension Operator {
    var isRelativeDateOperator: Bool {
        self == .olderThan || self == .withinLast
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
