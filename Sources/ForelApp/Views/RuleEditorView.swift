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
    @State private var showValidationErrors = false
    @State private var upgradeContext: ProUpgradeContext?
    @State private var hideImportError = false
    @EnvironmentObject private var model: AppModel
    private let preferredHeight: CGFloat
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    init(rule: Rule, preferredHeight: CGFloat = 680, onSave: @escaping (Rule) -> Void, onCancel: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.preferredHeight = max(680, preferredHeight)
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
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 18) {
                    if showValidationErrors, !validationMessages.isEmpty {
                        RuleValidationBanner(messages: validationMessages, onDismiss: { showValidationErrors = false })
                    }
                    if let error = rule.importError, !hideImportError {
                        RuleValidationBanner(messages: ["This rule cannot run because its Hazel import is incomplete. Recreate the rule to replace the missing parts.\n\(error)"], onDismiss: { hideImportError = true })
                    }
                    SectionLabel(title: "Basics")
                    GlassCard {
                        VStack(alignment: .leading, spacing: 14) {
                            GlassField(placeholder: "Rule name", text: $rule.name)
                            Toggle("Use Hazel rule ordering", isOn: $rule.isHazelImported)
                            if rule.isHazelImported {
                                Text("A matching rule stops later rules unless it continues matching. Subfolders are scanned when a matching rule runs rules on their contents.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ForelTheme.secondaryText)
                            } else {
                                ScopeEditor(depth: $rule.recursionDepth)
                            }

                            Picker("", selection: $rule.conditionMatch) {
                                Text("Match all conditions").tag(ConditionMatch.all)
                                Text("Match any condition").tag(ConditionMatch.any)
                                Text("Match no conditions").tag(ConditionMatch.none)
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
                                ConditionRow(condition: $condition, onRequestUpgrade: { upgradeContext = .feature($0) }) {
                                    rule.conditions.removeAll { $0.id == condition.id }
                                }
                            }
                        }
                        .padding(18)
                    }

                    HStack {
                        SectionLabel(title: "Actions")
                        Text("\(rule.actions.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ForelTheme.secondaryText)
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
                                ActionRow(action: $action, onRequestUpgrade: { upgradeContext = .feature($0) }) {
                                    rule.actions.removeAll { $0.id == action.id }
                                }
                            }
                        }
                        .padding(18)
                    }
                }.frame(minWidth: 780, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .scrollIndicators(.automatic)

            Divider().overlay(ForelTheme.divider)

            HStack {
                Toggle("Enabled", isOn: $rule.enabled)
                    .toggleStyle(.switch)
                    .tint(ForelTheme.accent)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(SecondaryButtonStyle())
                Button("Save") {
                    if hasValidationErrors {
                        showValidationErrors = true
                    } else {
                        if !model.isPro, rule.enabled, let feature = FreePlan.requiredFeature(for: rule) {
                            upgradeContext = .feature(feature)
                            return
                        }
                        showValidationErrors = false
                        onSave(rule)
                    }
                }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 880, height: preferredHeight)
        .background(ForelTheme.background)
        .background(WindowActivationBridge(showsDockIcon: model.showDockIcon))
        .sheet(item: $upgradeContext) { context in ProUpgradeView(context: context) }
    }

    private var conditionIssues: [RuleValidator.Issue] {
        RuleValidator.validate(rule.conditions)
    }

    private var actionIssues: [RuleValidator.Issue] {
        RuleValidator.validate(rule.actions)
    }

    private var validationMessages: [String] {
        (conditionIssues + actionIssues + RuleValidator.validateExecutionMode(rule)).map(\.message) + (rule.enabled && rule.importError != nil ? ["This incomplete imported rule cannot be enabled."] : [])
    }

    private var hasValidationErrors: Bool {
        !validationMessages.isEmpty
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(ForelTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct RuleValidationBanner: View {
    let messages: [String]
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ForelTheme.danger)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.danger.opacity(0.24)))
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
    @EnvironmentObject private var model: AppModel
    let onRequestUpgrade: (ProFeature) -> Void
    let onDelete: () -> Void

    var body: some View {
        if condition.kind == .conditionGroup {
            AnyView(ConditionGroupEditor(condition: $condition, onRequestUpgrade: onRequestUpgrade, onDelete: onDelete))
        } else {
            AnyView(standardRow)
        }
    }

    private var standardRow: some View {
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
            if condition.kind == .contents, !model.isPro {
                HStack {
                    Text("Document text is included in Free. Images and scanned PDFs require Pro OCR.")
                        .font(.caption)
                        .foregroundStyle(ForelTheme.secondaryText)
                    Button("Unlock OCR") { onRequestUpgrade(.ocr) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder private var conditionValue: some View {
        if condition.kind == .locked {
            Picker("Locked", selection: $condition.value) {
                Text("Locked").tag("true")
                Text("Unlocked").tag("false")
            }.labelsHidden()
        } else if condition.kind == .peerRanking {
            PeerRankingEditor(condition: $condition, onRequestUpgrade: onRequestUpgrade)
        } else if condition.kind == .dateComparison {
            DateComparisonEditor(condition: $condition)
        } else if condition.kind == .customTextMatch {
            CustomTextEditor(condition: $condition)
        } else if condition.kind == .customDateMatch {
            CustomDateEditor(condition: $condition)
        } else if condition.kind == .customTableMatch {
            CustomTableEditor(condition: $condition)
        } else if condition.kind == .contentsWithPassword {
            PasswordContentEditor(condition: $condition)
        } else if condition.kind == .spotlightAttribute || condition.kind == .scriptAttribute {
            SpotlightValueEditor(condition: $condition)
        } else if condition.kind == .hazelScriptCondition {
            HazelScriptConditionEditor(condition: $condition)
        } else if condition.kind == .currentTime {
            CurrentTimeScheduleEditor(condition: $condition)
        } else {
        switch RuleSchema.valueKind(for: condition.kind, operator: condition.operator) {
        case .noValue:
            EmptyView()
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
        if kind == .conditionGroup {
            return ConditionGroup(conditions: [Condition(ruleId: condition.ruleId, kind: .name, operator: .contains, value: "")]).encoded
        }
        if kind == .locked { return "true" }
        if kind == .subfileCount { return "0" }
        if kind == .currentTime { return "09:00" }
        if kind == .spotlightAttribute || kind == .scriptAttribute { return SpotlightCondition(key: "", type: .text, operand: "").encoded }
        if kind == .contentsWithPassword { return PasswordContentCondition().encoded }
        if kind == .customTableMatch { return CustomTableCondition().encoded }
        if kind == .customDateMatch { return CustomDateCondition().encoded }
        if kind == .customTextMatch { return CustomTextCondition().encoded }
        if kind == .dateComparison { return DateComparisonCondition().encoded }
        if kind == .peerRanking { return PeerRankingCondition().encoded }
        if kind == .hazelScriptCondition { return HazelScriptCondition().encoded }
        switch kind.baseValueKind {
        case .fileKind: return "image"
        case .size: return "0 MB"
        case .absoluteDate:
            return operator_.usesRelativeDateValue ? "7 days" : DateValueFormatter.string(from: Date())
        default: return ""
        }
    }
}

private struct CurrentTimeScheduleEditor: View {
    @Binding var condition: Condition
    var showRelation = true
    private var schedule: CurrentTimeCondition.Schedule? { CurrentTimeCondition.schedule(condition.value) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showRelation { Picker("Time relation", selection: Binding(
                get: { schedule?.relation ?? .exact },
                set: { relation in
                    var current = schedule ?? CurrentTimeCondition.Schedule(time: "")
                    current.relation = relation
                    condition.value = current.encoded
                }
            )) {
                Text("At").tag(CurrentTimeCondition.Relation.exact)
                Text("Before").tag(CurrentTimeCondition.Relation.before)
                Text("After").tag(CurrentTimeCondition.Relation.after)
            } }
            TextField("Time (HH:mm)", text: field(\.time))
            TextField("Weekdays 1–7 (Sunday = 1); blank = every day", text: field(\.weekdays))
            TextField("Days of month 1–31; blank = every day", text: field(\.monthdays))
            TextField("Months 1–12; blank = every month", text: field(\.months))
            Text("Separate numbers with commas. Selected weekday, day, and month restrictions must all match.")
                .font(.caption).foregroundStyle(ForelTheme.secondaryText)
        }
    }
    private func field(_ path: WritableKeyPath<CurrentTimeCondition.Schedule, String>) -> Binding<String> {
        Binding(get: { schedule?[keyPath: path] ?? "" }, set: { value in
            var current = schedule ?? CurrentTimeCondition.Schedule(time: "")
            current[keyPath: path] = value; condition.value = current.encoded
        })
    }
}

private struct PeerRankingEditor: View {
    @Binding var condition: Condition
    let onRequestUpgrade: (ProFeature) -> Void
    private var spec: PeerRankingCondition? { PeerRankingCondition.decode(condition.value) }
    var body: some View {
        if let spec {
            VStack(alignment: .leading) {
                HStack {
                    Picker("Attribute", selection: field(\.attribute, fallback: .modified)) {
                        ForEach(PeerRankingCondition.Attribute.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Order", selection: field(\.descending, fallback: true)) { Text("Highest / newest").tag(true); Text("Lowest / oldest").tag(false) }
                    TextField("Count", value: field(\.count, fallback: 1), format: .number).frame(width: 70)
                }
                Text("Rank visible items in the same folder that match every peer filter. Equal values use filename order.")
                    .font(.caption).foregroundStyle(ForelTheme.secondaryText)
                Text("Other conditions in an ALL group also filter peers. Script, content and context-dependent conditions cannot be used as peer filters.")
                    .font(.caption).foregroundStyle(ForelTheme.secondaryText)
                ForEach(Array(spec.filters.indices), id: \.self) { index in
                    AnyView(ConditionRow(condition: filterBinding(index), onRequestUpgrade: onRequestUpgrade) { update { if $0.filters.indices.contains(index) { $0.filters.remove(at: index) } } })
                }
                Button("Add peer filter") { update { $0.filters.append(Condition(ruleId: condition.ruleId, kind: .name, operator: .contains, value: "")) } }.buttonStyle(.link)
            }
        } else { Text("Invalid peer ranking; recreate this condition.").foregroundStyle(ForelTheme.danger) }
    }
    private func update(_ change: (inout PeerRankingCondition) -> Void) {
        guard var current = spec else { return }; change(&current); condition.value = current.encoded
    }
    private func field<T>(_ path: WritableKeyPath<PeerRankingCondition, T>, fallback: T) -> Binding<T> {
        Binding(get: { spec?[keyPath: path] ?? fallback }, set: { value in update { $0[keyPath: path] = value } })
    }
    private func filterBinding(_ index: Int) -> Binding<Condition> {
        Binding(get: { spec?.filters.indices.contains(index) == true ? spec!.filters[index] : Condition(ruleId: condition.ruleId, kind: .name, operator: .contains, value: "") }, set: { value in
            update { if $0.filters.indices.contains(index) { $0.filters[index] = value } }
        })
    }
}

private struct DateComparisonEditor: View {
    @Binding var condition: Condition
    private var spec: DateComparisonCondition? { DateComparisonCondition.decode(condition.value) }
    var body: some View {
        if let spec {
            VStack(alignment: .leading) {
                Picker("Date", selection: field(\.left, fallback: .modified)) {
                    ForEach(DateComparisonCondition.DateSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if spec.left == .custom { TextField("Custom date attribute", text: field(\.leftAttribute, fallback: "")) }
                Picker("Relation", selection: field(\.relation, fallback: .before)) {
                    ForEach(DateComparisonCondition.Relation.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if [.before, .after, .sameDay].contains(spec.relation) {
                    Picker("Other date", selection: field(\.right, fallback: .current)) {
                        ForEach(DateComparisonCondition.DateSource.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if spec.right == .custom { TextField("Other custom date attribute", text: field(\.rightAttribute, fallback: "")) }
                }
                if spec.left == .fixed || ([.before, .after, .sameDay].contains(spec.relation) && spec.right == .fixed) {
                    TextField("Fixed date, ISO 8601", text: field(\.fixedDate, fallback: ""))
                }
                if [.withinPrevious, .withinNext].contains(spec.relation) {
                    HStack {
                        TextField("Amount", value: field(\.amount, fallback: 1), format: .number)
                        Picker("Unit", selection: field(\.unit, fallback: .days)) {
                            ForEach(DateComparisonCondition.Unit.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                }
                if [.occursAt, .occursBefore, .occursAfter].contains(spec.relation) {
                    CurrentTimeScheduleEditor(condition: scheduleBinding, showRelation: false)
                }
            }
        } else { Text("Invalid date comparison; recreate this condition.").foregroundStyle(ForelTheme.danger) }
    }
    private func field<T>(_ path: WritableKeyPath<DateComparisonCondition, T>, fallback: T) -> Binding<T> {
        Binding(get: { spec?[keyPath: path] ?? fallback }, set: { value in
            guard var current = spec else { return }; current[keyPath: path] = value; condition.value = current.encoded
        })
    }
    private var scheduleBinding: Binding<Condition> {
        Binding(get: { var value = condition; value.value = spec?.schedule ?? "09:00"; return value }, set: { value in
            guard var current = spec else { return }; current.schedule = value.value; condition.value = current.encoded
        })
    }
}

private struct HazelScriptConditionEditor: View {
    @Binding var condition: Condition
    @State private var inspectedSource: String?
    @State private var inspectedBytes: String?
    @State private var inspectionMessage = ""
    @State private var inspecting = false
    private var spec: HazelScriptCondition? { HazelScriptCondition.decode(condition.value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let spec {
                HStack {
                    Picker("Language", selection: languageBinding) {
                        Text("Shell").tag(HazelScriptCondition.Language.shell)
                        Text("AppleScript").tag(HazelScriptCondition.Language.appleScript)
                        Text("JavaScript").tag(HazelScriptCondition.Language.javaScript)
                    }.labelsHidden()
                    Picker("Source", selection: modeBinding) {
                        Text("Embedded").tag("embedded")
                        Text("External file").tag("external")
                        if spec.compiledData != nil { Text("Imported compiled script").tag("compiled") }
                    }.labelsHidden()
                }
                if spec.externalPath != nil {
                    TextField("Absolute script path", text: externalBinding)
                } else if spec.compiledData != nil {
                    Button(inspecting ? "Inspecting…" : "Inspect Script") {
                        guard let encoded = spec.compiledData, let data = Data(base64Encoded: encoded) else { inspectionMessage = "Invalid compiled script"; return }
                        inspecting = true; inspectionMessage = ""
                        Task {
                            do {
                                let source = try await Task.detached { try CompiledScriptInspection.source(from: data) }.value
                                inspectedBytes = encoded; inspectedSource = source
                            } catch { inspectionMessage = "\(error)" }
                            inspecting = false
                        }
                    }.disabled(inspecting)
                    if !inspectionMessage.isEmpty { Text(inspectionMessage).font(.caption) }
                    if let source = inspectedSource, inspectedBytes == spec.compiledData {
                        ScrollView { Text(source).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(minHeight: 90, maxHeight: 200)
                        Button("Convert to Editable Source") {
                            update { current in
                                current.source = source; current.compiledData = nil; current.externalPath = nil; current.sourceIsHandler = true
                            }
                        }
                    }
                } else {
                    if spec.language == .shell { TextField("Absolute interpreter path", text: field(\.interpreter)) }
                    if spec.sourceIsHandler == true { Text("Editable complete hazelMatchFile handler").font(.caption) }
                    TextEditor(text: field(\.source)).font(.system(.body, design: .monospaced)).frame(minHeight: 90)
                }
                if spec.language != .shell {
                    TextField("Input attribute names, separated by commas", text: namesBinding(\.inputNames))
                    TextField("Output attribute names, separated by commas", text: namesBinding(\.outputNames))
                }
                Text("Condition scripts run while matching, including during Dry Run previews. Review imported scripts before enabling them.")
                    .font(.caption).foregroundStyle(ForelTheme.secondaryText)
            } else {
                Text("Invalid script condition; remove and recreate it.").foregroundStyle(ForelTheme.danger)
            }
        }
    }
    private func update(_ change: (inout HazelScriptCondition) -> Void) {
        guard var current = spec else { return }; change(&current); condition.value = current.encoded
    }
    private func field(_ path: WritableKeyPath<HazelScriptCondition, String>) -> Binding<String> {
        Binding(get: { spec?[keyPath: path] ?? "" }, set: { value in update { $0[keyPath: path] = value } })
    }
    private func namesBinding(_ path: WritableKeyPath<HazelScriptCondition, [String]>) -> Binding<String> {
        Binding(get: { spec?[keyPath: path].joined(separator: ", ") ?? "" }, set: { value in
            update { $0[keyPath: path] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        })
    }
    private var externalBinding: Binding<String> {
        Binding(get: { spec?.externalPath ?? "" }, set: { value in update { $0.externalPath = value } })
    }
    private var languageBinding: Binding<HazelScriptCondition.Language> {
        Binding(get: { spec?.language ?? .shell }, set: { value in update { current in
            current.language = value
            if value == .shell { current.inputNames = []; current.outputNames = []; current.compiledData = nil; current.sourceIsHandler = nil }
        } })
    }
    private var modeBinding: Binding<String> {
        Binding(get: { spec?.externalPath != nil ? "external" : spec?.compiledData != nil ? "compiled" : "embedded" }, set: { value in update { current in
            if value == "external" { current.externalPath = ""; current.source = ""; current.compiledData = nil; current.sourceIsHandler = nil }
            else if value == "embedded" { current.externalPath = nil; current.compiledData = nil; current.source = ""; current.sourceIsHandler = nil }
        } })
    }
}

private struct CustomTextEditor: View {
    @Binding var condition: Condition
    private var spec: CustomTextCondition? { CustomTextCondition.decode(condition.value) }
    var body: some View {
        if spec == nil {
            Text("Invalid text match; recreate this condition.").foregroundStyle(ForelTheme.danger)
        } else {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Capture names, separated by commas", text: field(\.names))
                    Picker("Source", selection: field(\.source)) {
                        Text("Name").tag("name"); Text("Full name").tag("fullName"); Text("Contents").tag("contents"); Text("Tags").tag("tags")
                    }.labelsHidden()
                }
                TextField("Regular expression with one capture group per name", text: field(\.pattern))
                Toggle("Collect all matches as lists", isOn: Binding(get: { spec?.collectAllMatches ?? false }, set: { enabled in
                    guard var current = spec else { return }; current.collectAllMatches = enabled; condition.value = current.encoded
                }))
            }
        }
    }
    private func field(_ keyPath: WritableKeyPath<CustomTextCondition, String>) -> Binding<String> {
        Binding(get: { spec?[keyPath: keyPath] ?? "" }, set: { value in
            guard var current = spec else { return }; current[keyPath: keyPath] = value; condition.value = current.encoded
        })
    }
}

private struct CustomDateEditor: View {
    @Binding var condition: Condition
    private var spec: CustomDateCondition? { CustomDateCondition.decode(condition.value) }
    var body: some View {
        if spec == nil {
            Text("Invalid date match; recreate this condition.").foregroundStyle(ForelTheme.danger)
        } else {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Attribute name", text: field(\.name))
                    Picker("Source", selection: field(\.source)) {
                        Text("Name").tag("name"); Text("Full name").tag("fullName"); Text("Contents").tag("contents")
                    }.labelsHidden()
                }
                HStack {
                    TextField("Regex with one date capture", text: field(\.pattern))
                    TextField("Date format, e.g. yyyy-MM-dd", text: field(\.format))
                }
            }
        }
    }
    private func field(_ keyPath: WritableKeyPath<CustomDateCondition, String>) -> Binding<String> {
        Binding(get: { spec?[keyPath: keyPath] ?? "" }, set: { value in
            guard var current = spec else { return }
            current[keyPath: keyPath] = value; condition.value = current.encoded
        })
    }
}

private struct CustomTableEditor: View {
    @Binding var condition: Condition
    private var spec: CustomTableCondition? { CustomTableCondition.decode(condition.value) }
    var body: some View {
        if spec == nil {
            Text("Invalid table; recreate this condition.").foregroundStyle(ForelTheme.danger)
        } else {
            VStack(alignment: .leading) {
                HStack {
                    TextField("Attribute prefix", text: field(\.prefix))
                    TextField("Match column", text: field(\.matchColumn))
                    Picker("Source", selection: field(\.source)) {
                        Text("Name").tag("name"); Text("Full name").tag("fullName"); Text("Contents").tag("contents")
                    }.labelsHidden()
                    Picker("Match", selection: field(\.mode)) { Text("is").tag("is"); Text("contains").tag("contains") }.labelsHidden()
                }
                Toggle("Read table from file", isOn: fromFile)
                if spec?.filePath != nil {
                    TextField("UTF-8 table file path", text: optionalField(\.filePath, fallback: ""))
                    TextField("Column separator", text: optionalField(\.separator, fallback: ","))
                    Toggle("Trim whitespace from cells", isOn: trimCells)
                } else {
                    Text("Enter a header and rows, with columns separated by tabs. Matched values become prefix.column attributes.")
                        .font(.caption).foregroundStyle(ForelTheme.secondaryText)
                    TextEditor(text: field(\.table)).frame(minHeight: 75)
                }
            }
        }
    }
    private func field(_ keyPath: WritableKeyPath<CustomTableCondition, String>) -> Binding<String> {
        Binding(get: { spec?[keyPath: keyPath] ?? "" }, set: { value in
            guard var current = spec else { return }
            current[keyPath: keyPath] = value; condition.value = current.encoded
        })
    }
    private func optionalField(_ keyPath: WritableKeyPath<CustomTableCondition, String?>, fallback: String) -> Binding<String> {
        Binding(get: { spec?[keyPath: keyPath] ?? fallback }, set: { value in
            guard var current = spec else { return }; current[keyPath: keyPath] = value; condition.value = current.encoded
        })
    }
    private var fromFile: Binding<Bool> {
        Binding(get: { spec?.filePath != nil }, set: { enabled in
            guard var current = spec else { return }; current.filePath = enabled ? "" : nil; condition.value = current.encoded
        })
    }
    private var trimCells: Binding<Bool> {
        Binding(get: { spec?.trimCells ?? false }, set: { value in
            guard var current = spec else { return }; current.trimCells = value; condition.value = current.encoded
        })
    }
}

private struct PasswordContentEditor: View {
    @Binding var condition: Condition
    @State private var password = ""
    @State private var message = ""
    private var spec: PasswordContentCondition? { PasswordContentCondition.decode(condition.value) }
    var body: some View {
        if spec == nil {
            Text("Invalid password reference; recreate this condition.").foregroundStyle(ForelTheme.danger)
        } else {
            VStack(alignment: .leading) {
                HStack {
                    SecureField("PDF password", text: $password)
                    Button("Save Password") {
                        guard var current = spec else { return }
                        do {
                            let id = UUID().uuidString
                            try PDFPasswordStore.save(password, for: id)
                            current.credentialID = id; condition.value = current.encoded
                            password = ""; message = "Password saved in Keychain."
                        } catch { message = error.localizedDescription }
                    }
                    if spec?.referenceIsValid == true {
                        Button("Remove") {
                            guard var current = spec else { return }
                            current.credentialID = ""; condition.value = current.encoded; message = "Password reference removed from this rule."
                        }
                    }
                }
                if condition.operator != .isBlank && condition.operator != .isNotBlank {
                    TextField("Text to match", text: field(\.operand))
                }
                Text("The password is saved in Forel’s Keychain entry and is not included in exports.")
                    .font(.caption).foregroundStyle(ForelTheme.secondaryText)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(ForelTheme.secondaryText) }
            }
        }
    }
    private func field(_ keyPath: WritableKeyPath<PasswordContentCondition, String>) -> Binding<String> {
        Binding(get: { spec?[keyPath: keyPath] ?? "" }, set: { value in
            guard var current = spec else { return }
            current[keyPath: keyPath] = value; condition.value = current.encoded
        })
    }
}

private struct SpotlightValueEditor: View {
    @Binding var condition: Condition
    private var spec: SpotlightCondition? { SpotlightCondition.decode(condition.value) }
    var body: some View {
        if spec == nil {
            Text("Invalid Spotlight condition; choose another condition and recreate it.").foregroundStyle(ForelTheme.danger)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                TextField(condition.kind == .scriptAttribute ? "Rule attribute name" : "Attribute key, e.g. kMDItemAuthors", text: field(\.key))
                HStack {
                    Picker("Value type", selection: typeBinding) {
                        Text("Text").tag(SpotlightCondition.ValueType.text)
                        Text("Number").tag(SpotlightCondition.ValueType.number)
                        Text("Date").tag(SpotlightCondition.ValueType.date)
                        Text("Boolean").tag(SpotlightCondition.ValueType.boolean)
                    }.labelsHidden()
                    if spec?.type == .boolean {
                        Picker("Value", selection: field(\.operand)) {
                            Text("True").tag("true"); Text("False").tag("false")
                        }.labelsHidden()
                    } else {
                        TextField(spec?.type == .date ? "2026-01-01T00:00:00Z" : "Value", text: field(\.operand))
                    }
                }
            }
        }
    }
    private func field(_ keyPath: WritableKeyPath<SpotlightCondition, String>) -> Binding<String> {
        Binding(get: { spec?[keyPath: keyPath] ?? "" }, set: { value in
            guard var current = spec else { return }
            current[keyPath: keyPath] = value; condition.value = current.encoded
        })
    }
    private var typeBinding: Binding<SpotlightCondition.ValueType> {
        Binding(get: { spec?.type ?? .text }, set: { type in
            guard var current = spec else { return }
            current.type = type; current.operand = type == .boolean ? "true" : ""
            condition.operator = .is; condition.value = current.encoded
        })
    }
}

private struct ConditionGroupEditor: View {
    @Binding var condition: Condition
    let onRequestUpgrade: (ProFeature) -> Void
    let onDelete: () -> Void
    private var group: ConditionGroup? { ConditionGroup.decode(condition.value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Nested conditions")
                Picker("Match", selection: matchBinding) {
                    Text("All").tag(ConditionGroup.Match.all)
                    Text("Any").tag(ConditionGroup.Match.any)
                    Text("None").tag(ConditionGroup.Match.none)
                }.labelsHidden().frame(width: 90)
                Picker("Target", selection: targetBinding) {
                    Text("Current item").tag(ConditionGroup.Target.current)
                    Text("Enclosing folder").tag(ConditionGroup.Target.parent)
                    Text("Any sibling").tag(ConditionGroup.Target.anySibling)
                    Text("All siblings").tag(ConditionGroup.Target.allSiblings)
                    Text("Any child").tag(ConditionGroup.Target.anyChild)
                    Text("All children").tag(ConditionGroup.Target.allChildren)
                }.labelsHidden()
                Button(role: .destructive, action: onDelete) { Image(systemName: "minus") }
                    .buttonStyle(IconButtonStyle(role: .destructive))
            }
            if let group {
                ForEach(Array(group.conditions.indices), id: \.self) { index in
                    HStack(alignment: .top) {
                        AnyView(ConditionRow(condition: childBinding(index), onRequestUpgrade: onRequestUpgrade) { remove(index) })
                        VStack(spacing: 2) {
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index + 1 == group.conditions.count)
                        }.buttonStyle(.plain)
                    }
                }
                Button("Add condition") {
                    update { $0.conditions.append(Condition(ruleId: condition.ruleId, kind: .name, operator: .contains, value: "")) }
                }.buttonStyle(.link)
            } else {
                Text("This nested condition is invalid. Remove and recreate it.").foregroundStyle(ForelTheme.danger)
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ForelTheme.surfaceBorder))
    }

    private var matchBinding: Binding<ConditionGroup.Match> {
        Binding(get: { group?.match ?? .all }, set: { value in update { $0.match = value } })
    }
    private var targetBinding: Binding<ConditionGroup.Target> {
        Binding(get: { group?.target ?? .current }, set: { value in update { $0.target = value } })
    }
    private func childBinding(_ index: Int) -> Binding<Condition> {
        Binding(get: {
            guard let group, group.conditions.indices.contains(index) else {
                return Condition(ruleId: condition.ruleId, kind: .name, operator: .contains, value: "")
            }
            return group.conditions[index]
        }, set: { value in update { if $0.conditions.indices.contains(index) { $0.conditions[index] = value } } })
    }
    private func update(_ change: (inout ConditionGroup) -> Void) {
        guard var current = group else { return }
        change(&current); condition.value = current.encoded
    }
    private func remove(_ index: Int) { update { if $0.conditions.indices.contains(index) { $0.conditions.remove(at: index) } } }
    private func move(_ index: Int, by offset: Int) {
        update { group in
            let target = index + offset
            guard group.conditions.indices.contains(index), group.conditions.indices.contains(target) else { return }
            group.conditions.swapAt(index, target)
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
    @EnvironmentObject private var model: AppModel
    let onRequestUpgrade: (ProFeature) -> Void

    var body: some View {
        RuleSelectMenu(title: selection.label) {
            ForEach(Array(RuleSchema.actionKindGroups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Section(title) {
                        ForEach(group.kinds, id: \.self) { kind in
                            Button {
                                select(kind)
                            } label: {
                                HStack {
                                    Image(systemName: kind.iconSystemName)
                                        .frame(width: 16)
                                    Text(kind.label)
                                    if !model.isPro, FreePlan.requiredFeature(for: kind) != nil {
                                        Label("Pro", systemImage: "lock.fill")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ForEach(group.kinds, id: \.self) { kind in
                        Button {
                            select(kind)
                        } label: {
                            HStack {
                                Image(systemName: kind.iconSystemName)
                                    .frame(width: 16)
                                Text(kind.label)
                                if !model.isPro, FreePlan.requiredFeature(for: kind) != nil {
                                    Label("Pro", systemImage: "lock.fill")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func select(_ kind: ActionKind) {
        if !model.isPro, let feature = FreePlan.requiredFeature(for: kind) {
            onRequestUpgrade(feature)
        } else {
            selection = kind
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
    private let units = ["minutes", "hours", "days", "weeks", "months", "years"]

    var body: some View {
        HStack(spacing: 8) {
            GlassField(placeholder: "7", text: numberBinding)
                .frame(width: 72)
            StringSelectMenu(selection: unitBinding, options: units)
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
        // omittingEmptySubsequences: false keeps "" as the number when the
        // field is transiently empty mid-edit, so the unit survives keystrokes.
        let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let number = pieces.first?.filter(\.isNumber)
        let rawUnit = pieces.count > 1 ? pieces[1].lowercased() : "days"
        let unit = rawUnit.hasSuffix("s") ? rawUnit : rawUnit + "s"
        return ((number?.isEmpty == false ? number! : "7"), units.contains(unit) ? unit : "days")
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
        let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
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

private struct ApplicationPathPickerField: View {
    @Binding var path: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                iconView
                TextField("Application", text: $path)
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
        if FileManager.default.fileExists(atPath: path) {
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
            path = app.path
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
    @EnvironmentObject private var model: AppModel
    let onRequestUpgrade: (ProFeature) -> Void
    let onDelete: () -> Void
    @State private var showingOptions = false
    @EnvironmentObject private var settingsNavigation: SettingsNavigation
    @State private var inspectedSource: String?
    @State private var inspectedBytes: String?
    @State private var inspectionMessage = ""
    @State private var inspecting = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ActionKindMenu(selection: kindBinding, onRequestUpgrade: onRequestUpgrade)
            .frame(minWidth: 160, alignment: .leading)

            Group {
                if !model.isPro, let feature = FreePlan.requiredFeature(for: action.kind) {
                    Button("Unlock \(feature.title)") { onRequestUpgrade(feature) }
                        .buttonStyle(.link)
                } else {
                    actionParams
                }
            }
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
        case .moveToFolder:
            VStack(alignment: .leading) {
                Picker("Move destination", selection: structuredMode(isSort: true)) {
                    Text("Choose folder").tag(false); Text("Sort into subfolder").tag(true)
                }.pickerStyle(.segmented)
                if action.params["hazel_sort_subfolder"]?.boolValue == true {
                    HazelPatternEditor(action: $action, isFolder: true)
                } else { FolderField(placeholder: "Destination folder", path: paramBinding(ActionParam.destination), hint: "Add {year}, {month}, or {day} for dated folders, e.g. …/Archive/{year}/{month}") }
            }
        case .copyToFolder:
            FolderField(placeholder: "Destination folder", path: paramBinding(ActionParam.destination), hint: "Add {year}, {month}, or {day} for dated folders, e.g. …/Archive/{year}/{month}")
        case .makeAlias:
            FolderField(placeholder: "Destination folder", path: paramBinding(ActionParam.destination))
        case .syncToFolder:
            VStack(alignment: .leading, spacing: 6) {
                FolderField(placeholder: "Destination folder", path: paramBinding(ActionParam.destination))
                Text("Sync replaces destination files. When syncing a folder, files removed from the source are also deleted from its destination copy. These changes cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(ForelTheme.secondaryText)
                    .textSelection(.enabled)
            }
        case .rename:
            VStack(alignment: .leading) {
                Picker("Rename pattern", selection: structuredMode(isSort: false)) {
                    Text("Basic").tag(false); Text("Attributes").tag(true)
                }.pickerStyle(.segmented)
                if action.params["hazel_pattern_tokens"] != nil {
                    HazelPatternEditor(action: $action, isFolder: false)
                } else {
                    RenamePatternEditor(pattern: paramBinding(ActionParam.pattern), cleanFileName: action.params[ActionParam.cleanFileName]?.boolValue == true)
                }
            }
        case .addTag, .removeTag:
            VStack(alignment: .leading, spacing: 5) {
                if action.kind == .removeTag { Toggle("Remove all existing tags", isOn: removeAllTagsBinding) }
                if action.kind != .removeTag || action.params["remove_all_tags"]?.boolValue != true {
                    TagTokensEditor(tags: tagsBinding, placeholder: action.kind == .addTag ? "Add tag" : "Tag")
                    if action.params["hazel_pattern_tokens"] != nil {
                        HazelPatternEditor(action: $action, isFolder: false, isTag: true)
                        Button("Remove generated tag") {
                            var params: [String: JSONValue] = [:]
                            if case .object(let existing) = action.params { params = existing }
                            params.removeValue(forKey: "hazel_pattern_tokens")
                            action.params = .object(params)
                        }
                    } else {
                        Button("Add generated tag") {
                            var params: [String: JSONValue] = [:]
                            if case .object(let existing) = action.params { params = existing }
                            params["hazel_pattern_tokens"] = .array([.object(["type": .string("name")])])
                            action.params = .object(params)
                        }
                    }
                }
            }
        case .setColorLabel:
            ColorLabelPicker(selection: paramBinding(ActionParam.color), allowNone: true)
        case .setFinderLabel:
            VStack(alignment: .leading, spacing: 6) {
                ColorLabelPicker(selection: paramBinding(ActionParam.color), allowNone: true)
                Text("Colored tags of other colors are removed; uncolored tags are kept.")
                    .font(.caption)
                    .foregroundStyle(ForelTheme.secondaryText)
                    .textSelection(.enabled)
            }
        case .setLocked, .setExtensionHidden:
            Toggle(action.kind == .setLocked ? "Locked" : "Hide extension", isOn: flagBinding)
        case .setFinderComment:
            if action.params["hazel_pattern_tokens"] != nil {
                HazelPatternEditor(action: $action, isFolder: false, isComment: true)
            } else {
                VStack(alignment: .leading) {
                    GlassField(placeholder: "Finder comment", text: paramBinding(ActionParam.comment))
                    Toggle("Keep existing comment before this text", isOn: commentAppendBinding)
                }
            }
        case .runScript:
            VStack(alignment: .leading, spacing: 6) {
                GlassField(placeholder: "Bash script (file path in $FOREL_FILE)", text: paramBinding(ActionParam.script))
                Text("Runs once per matching file. Use \"$FOREL_FILE\" for its full path. Dry Run does not execute scripts; script changes cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(ForelTheme.secondaryText)
                    .textSelection(.enabled)
            }
        case .runHazelShellScript:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Script", selection: paramBinding(ActionParam.shellMode, defaultValue: "embedded")) {
                    Text("Embedded").tag("embedded")
                    Text("External executable").tag("external")
                }
                if action.params[ActionParam.shellMode]?.stringValue == "external" {
                    GlassField(placeholder: "Absolute executable path", text: externalShellPathBinding)
                } else {
                    GlassField(placeholder: "Interpreter path", text: paramBinding(ActionParam.shell, defaultValue: "/bin/zsh"))
                    TextEditor(text: paramBinding(ActionParam.script))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                }
                Text("Runs once per matching file. The full path is the first argument. Dry Run does not execute scripts; script changes cannot be undone.")
                    .font(.caption)
                    .foregroundStyle(ForelTheme.secondaryText)
                    .textSelection(.enabled)
            }
        case .hazelContinue:
            Text("Continue matching later rules for this file.")
                .font(.caption).foregroundStyle(ForelTheme.secondaryText)
        case .hazelRecurse:
            Text("Run rules on the contents of this folder. Requires Hazel rule ordering.")
                .font(.caption).foregroundStyle(ForelTheme.secondaryText)
        case .runHazelAppleScript:
            compiledScriptInspector
        case .runHazelOSA:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Language", selection: paramBinding(ActionParam.osaLanguage, defaultValue: "AppleScript")) {
                    Text("AppleScript").tag("AppleScript")
                    Text("JavaScript").tag("JavaScript")
                }
                Picker("Script", selection: paramBinding(ActionParam.osaMode, defaultValue: "embedded")) {
                    Text("Embedded").tag("embedded")
                    Text("External").tag("external")
                    if action.params[ActionParam.compiledAppleScript] != nil { Text("Imported compiled script").tag("compiled") }
                    if action.params[ActionParam.osaMode]?.stringValue == "sourceHandler" { Text("Editable handler").tag("sourceHandler") }
                    if action.params[ActionParam.osaMode]?.stringValue == "legacySource" { Text("Editable legacy handler").tag("legacySource") }
                }
                if action.params[ActionParam.osaMode]?.stringValue == "compiled" {
                    compiledScriptInspector
                } else if action.params[ActionParam.osaMode]?.stringValue == "external" {
                    GlassField(placeholder: "Absolute script path", text: paramBinding(ActionParam.osaPath))
                } else {
                    TextEditor(text: paramBinding(ActionParam.script)).font(.system(.body, design: .monospaced)).frame(minHeight: 100)
                }
                GlassField(placeholder: "Input attributes, comma separated", text: attributeNamesBinding(ActionParam.osaInputs))
                GlassField(placeholder: "Output attributes, comma separated", text: attributeNamesBinding(ActionParam.osaOutputs))
            }
        case .runWorkflow:
            GlassField(placeholder: "Absolute workflow path", text: paramBinding(ActionParam.workflowPath))
        case .upload:
            VStack(alignment: .leading, spacing: 6) {
                Picker("Server", selection: paramBinding("upload_server_id")) {
                    Text("Choose a server").tag("")
                    if let id = action.params["upload_server_id"]?.stringValue, !id.isEmpty,
                       !model.uploadServers.contains(where: { $0.id == id }) {
                        Text("Missing server").tag(id)
                    }
                    ForEach(model.uploadServers, id: \.id) { server in
                        Text(server.name).tag(server.id)
                    }
                }
                .onChange(of: action.params["upload_server_id"]?.stringValue) { id in
                    if let server = model.uploadServers.first(where: { $0.id == id }),
                       [.ftp, .ftpsExplicit, .ftpsImplicit].contains(server.protocolType) {
                        var params: [String: JSONValue] = [:]
                        if case .object(let existing) = action.params { params = existing }
                        params[ActionParam.onConflict] = .string(MoveConflictResolution.replace.rawValue)
                        action.params = .object(params)
                    }
                }
                if model.uploadServers.isEmpty || (action.params["upload_server_id"]?.stringValue).map({ id in !id.isEmpty && !model.uploadServers.contains(where: { $0.id == id }) }) == true {
                    Text(model.uploadServers.isEmpty ? "Add a server in Settings to use this action." : "This server is missing. Choose another server in Settings or below.")
                        .font(.caption).foregroundStyle(ForelTheme.secondaryText)
                    Button("Open Servers Settings") {
                        settingsNavigation.selectedCategory = .servers
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }.buttonStyle(.link)
                }
                GlassField(placeholder: "Server folder, e.g. /uploads", text: paramBinding("upload_remote_path", defaultValue: "/"))
            }
        case .runShortcut:
            ShortcutPicker(selection: paramBinding(ActionParam.shortcutName))
        case .openApplication:
            ApplicationPathPickerField(path: paramBinding(ActionParam.applicationPath))
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
        case .pause:
            GlassField(placeholder: "Seconds", text: paramBinding(ActionParam.durationSeconds, defaultValue: "1"))
        case .displayNotification:
            VStack(alignment: .leading) {
                if action.params["hazel_pattern_tokens"] != nil {
                    HazelPatternEditor(action: $action, isFolder: false, isNotification: true)
                } else {
                    GlassField(placeholder: "Notification text", text: paramBinding(ActionParam.notificationText))
                    Button("Use a pattern") {
                        var params: [String: JSONValue] = [:]
                        if case .object(let existing) = action.params { params = existing }
                        params["hazel_pattern_tokens"] = .array([.object(["type": .string("literal"), "value": .string(params[ActionParam.notificationText]?.stringValue ?? "")])])
                        action.params = .object(params)
                    }.buttonStyle(.link)
                }
                Toggle("Play notification sound", isOn: notificationSoundBinding)
            }
        case .moveToTrash, .delete, .importError, .archive, .openDefault, .showInFinder, .ignore:
            Text("No parameters")
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(minHeight: 32, alignment: .center)
        }
    }

    private var compiledScriptInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inspect this script before enabling the rule. Inspection does not run it.").font(.caption)
            Button(inspecting ? "Inspecting…" : "Inspect Script") {
                guard let encoded = action.params[ActionParam.compiledAppleScript]?.stringValue, let data = Data(base64Encoded: encoded) else {
                    inspectionMessage = "Invalid compiled script"; return
                }
                inspecting = true
                inspectionMessage = ""
                Task {
                    do {
                        let source = try await Task.detached { try CompiledScriptInspection.source(from: data) }.value
                        inspectedBytes = encoded
                        inspectedSource = source
                    } catch { inspectionMessage = "\(error)" }
                    inspecting = false
                }
            }.disabled(inspecting)
            if !inspectionMessage.isEmpty { Text(inspectionMessage).font(.caption) }
            if let source = inspectedSource, inspectedBytes == action.params[ActionParam.compiledAppleScript]?.stringValue {
                ScrollView { Text(source).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(minHeight: 100, maxHeight: 220)
                Button("Convert to Editable Source") {
                    var params: [String: JSONValue] = [:]
                    if case .object(let existing) = action.params { params = existing }
                    let legacy = action.kind == .runHazelAppleScript
                    params[ActionParam.script] = .string(source)
                    params[ActionParam.osaMode] = .string(legacy ? "legacySource" : "sourceHandler")
                    if legacy { params[ActionParam.osaLanguage] = .string("AppleScript") }
                    action.params = .object(params)
                    action.kind = .runHazelOSA
                }
            }
        }
    }

    private var kindBinding: Binding<ActionKind> {
        Binding(
            get: { action.kind },
            set: { newKind in
                var params: [String: JSONValue] = [:]
                if newKind == .importToLibrary {
                    params[ActionParam.libraryType] = .string(LibraryType.music.rawValue)
                } else if newKind == .openApplication {
                    params[ActionParam.passFileToApplication] = .bool(true)
                } else if newKind == .runHazelShellScript {
                    params[ActionParam.script] = .string("")
                    params[ActionParam.shell] = .string("/bin/zsh")
                } else if newKind == .runHazelOSA {
                    params[ActionParam.osaLanguage] = .string("AppleScript")
                    params[ActionParam.osaMode] = .string("embedded")
                    params[ActionParam.script] = .string("")
                } else if newKind == .upload {
                    params["upload_server_id"] = .string("")
                    params["upload_remote_path"] = .string("/")
                }
                action = Action(id: action.id, ruleId: action.ruleId, kind: newKind, params: .object(params), position: action.position)
            }
        )
    }

    private func structuredMode(isSort: Bool) -> Binding<Bool> {
        Binding(get: { isSort ? action.params["hazel_sort_subfolder"]?.boolValue == true : action.params["hazel_pattern_tokens"] != nil }, set: { enabled in
            PatternAuthoring.setStructured(enabled, on: &action)
        })
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

    private var flagBinding: Binding<Bool> {
        Binding(get: { action.params[ActionParam.enabled]?.boolValue ?? true }, set: { value in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params[ActionParam.enabled] = .bool(value)
            action.params = .object(params)
        })
    }

    private var externalShellPathBinding: Binding<String> {
        Binding(get: { action.params[ActionParam.shellPath]?.stringValue ?? "" }, set: { path in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params[ActionParam.shellPath] = .string(path)
            params.removeValue(forKey: ActionParam.shellBookmark)
            action.params = .object(params)
        })
    }

    private var notificationSoundBinding: Binding<Bool> {
        Binding(get: { action.params[ActionParam.notificationSound]?.boolValue ?? false }, set: { value in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params[ActionParam.notificationSound] = .bool(value)
            action.params = .object(params)
        })
    }

    private var commentAppendBinding: Binding<Bool> {
        Binding(get: { action.params[ActionParam.includeExistingComment]?.boolValue == true }, set: { value in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params[ActionParam.includeExistingComment] = .bool(value)
            action.params = .object(params)
        })
    }

    private func attributeNamesBinding(_ key: String) -> Binding<String> {
        Binding(get: { (action.params[key]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ") }, set: { text in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params[key] = .stringArray(text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            action.params = .object(params)
        })
    }

    private var removeAllTagsBinding: Binding<Bool> {
        Binding(get: { action.params["remove_all_tags"]?.boolValue == true }, set: { value in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params["remove_all_tags"] = .bool(value)
            action.params = .object(params)
        })
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
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ForelTheme.primaryText)

            switch action.kind {
            case .runShortcut:
                shortcutOptions
            case .openApplication:
                openApplicationOptions
            case .showInFinder, .openDefault:
                Toggle("Bring to front", isOn: bringToFrontBinding)
            case .moveToFolder:
                conflictResolutionOptions
                folderStructureOptions
                Toggle("Move identical files to Trash", isOn: discardDuplicatesBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("When a destination exists, regular files are compared by content.")
                    .font(.caption)
                    .foregroundStyle(ForelTheme.secondaryText)
            case .copyToFolder:
                conflictResolutionOptions
                folderStructureOptions
                Toggle("Do not copy identical files", isOn: skipDuplicatesBinding)
                    .toggleStyle(.switch).controlSize(.small)
                Text("Regular files are compared by content.")
                    .font(.caption).foregroundStyle(ForelTheme.secondaryText)
            case .upload:
                conflictResolutionOptions
                folderStructureOptions
            case .importToLibrary, .uncompress:
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

    private var openApplicationOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Bring to front", isOn: bringToFrontBinding)
            Toggle(isOn: passFileToApplicationBinding) {
                Text("Pass matched file to app")
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var bringToFrontBinding: Binding<Bool> {
        Binding(get: { action.params[ActionParam.bringToFront]?.boolValue ?? (action.kind == .openApplication) }, set: { value in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params[ActionParam.bringToFront] = .bool(value)
            action.params = .object(params)
        })
    }

    private var conflictResolutionOptions: some View {
        let defaultResolution = action.kind == .importToLibrary ? MoveConflictResolution.skip.rawValue : MoveConflictResolution.rename.rawValue
        let protocolType = model.uploadServers.first { $0.id == action.params["upload_server_id"]?.stringValue }?.protocolType
        let ftp = action.kind == .upload && protocolType.map { [.ftp, .ftpsExplicit, .ftpsImplicit].contains($0) } == true
        let options = MoveConflictResolution.allCases.filter {
            ($0 != .discard || action.kind == .moveToFolder) && ($0 != .rename || action.kind != .importToLibrary) && (!ftp || $0 == .replace)
        }.map(\.rawValue)
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

    private var folderStructureOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folder structure").font(.system(size: 11, weight: .medium)).foregroundStyle(ForelTheme.secondaryText)
            StringSelectMenu(selection: paramBinding(ActionParam.folderStructure, defaultValue: FolderStructureMode.none.rawValue),
                             options: FolderStructureMode.allCases.map(\.rawValue),
                             label: { FolderStructureMode(rawValue: $0)?.label ?? $0 })
        }
    }

    private var skipDuplicatesBinding: Binding<Bool> {
        Binding(get: { action.params[ActionParam.skipDuplicates]?.boolValue ?? false }, set: { value in
            var params: [String: JSONValue] = [:]
            if case .object(let existing) = action.params { params = existing }
            params[ActionParam.skipDuplicates] = .bool(value)
            action.params = .object(params)
        })
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

    private var discardDuplicatesBinding: Binding<Bool> {
        Binding(
            get: { action.params[ActionParam.discardDuplicates]?.boolValue == true },
            set: { newValue in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { dict = existing }
                dict[ActionParam.discardDuplicates] = .bool(newValue)
                action.params = .object(dict)
            }
        )
    }

    private var passFileToApplicationBinding: Binding<Bool> {
        Binding(
            get: { ActionExecutor.passesFileToApplication(action) },
            set: { newValue in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { dict = existing }
                dict[ActionParam.passFileToApplication] = .bool(newValue)
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

/// Imported Hazel patterns are structured, so editing a visible token updates
/// the same data that the executor uses.
private struct HazelPatternEditor: View {
    @Binding var action: Action
    let isFolder: Bool
    var isComment = false
    var isNotification = false
    var isTag = false

    private var tokens: [JSONValue] { action.params["hazel_pattern_tokens"]?.arrayValue ?? [] }
    private var captures: [String] { (action.params["hazel_capture_names"]?.arrayValue ?? []).compactMap(\.stringValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(isTag ? "Generated tag using:" : (isNotification ? "Notification using:" : (isComment ? "Comment using:" : (isFolder ? "Sort into a subfolder named:" : "Rename using:"))))
                .font(.caption).foregroundStyle(ForelTheme.secondaryText)
            ForEach(Array(tokens.indices), id: \.self) { index in
                VStack(alignment: .leading) {
                HStack {
                    Picker("Token", selection: field(index, "type", fallback: "literal")) {
                        Text("Text").tag("literal")
                        Text("Name").tag("name")
                        Text("Extension").tag("extension")
                        Text("Extension without dot").tag("extensionBare")
                        Text("File size").tag("size")
                        if action.kind == .rename { Text("Original extension if needed").tag("extensionIfMissing") }
                        if isNotification { Text("Full name").tag("fullName"); Text("Rule name").tag("rule") }
                        if isComment { Text("Existing comment").tag("comment") }
                        Text("Rule attribute").tag("attribute")
                        Text("Rule date").tag("attributeDate")
                        Text("Script list").tag("attributeList")
                        Text("Script number").tag("attributeNumber")
                        Text("Spotlight attribute").tag("spotlight")
                        Text("Captured value").tag("capture")
                        Text("Date").tag("date")
                        if !isNotification { Text("Counter").tag("counter") }
                        if isFolder { Text("Subfolder separator").tag("pathSeparator") }
                    }.labelsHidden().frame(width: 130)
                    let type = tokens[index]["type"]?.stringValue ?? "literal"
                    if type == "literal" {
                        TextField("Text", text: field(index, "value"))
                    } else if type == "attribute" {
                        TextField("Rule attribute", text: field(index, "value"))
                    } else if type == "attributeList" {
                        TextField("Script list attribute", text: field(index, "value"))
                        Picker("Items", selection: field(index, "selection", fallback: "all")) {
                            Text("All").tag("all"); Text("First").tag("first"); Text("Last").tag("last"); Text("Position").tag("index")
                        }.labelsHidden()
                        if (tokens[index]["selection"]?.stringValue ?? "all") == "all" {
                            TextField("Separator", text: field(index, "separator", fallback: ", "))
                        }
                        if tokens[index]["selection"]?.stringValue == "index" {
                            TextField("Position (negative from end)", text: field(index, "index", fallback: "1"))
                        }
                    } else if type == "attributeNumber" {
                        TextField("Script number attribute", text: field(index, "value"))
                        TextField("Adjustment", text: field(index, "adjustment", fallback: "0"))
                    } else if type == "spotlight" {
                        TextField("Spotlight key", text: field(index, "source"))
                        Picker("Type", selection: field(index, "valueType", fallback: "text")) {
                            Text("Text").tag("text"); Text("Number").tag("number"); Text("Date").tag("date"); Text("List").tag("list"); Text("Boolean").tag("boolean")
                        }.labelsHidden()
                        if tokens[index]["valueType"]?.stringValue == "date" { TextField("yyyy-MM-dd", text: field(index, "value", fallback: "yyyy-MM-dd")) }
                        if tokens[index]["valueType"]?.stringValue == "list" {
                            Picker("Items", selection: field(index, "selection", fallback: "all")) { Text("All").tag("all"); Text("First").tag("first"); Text("Last").tag("last"); Text("Position").tag("index") }.labelsHidden()
                            if (tokens[index]["selection"]?.stringValue ?? "all") == "all" { TextField("Separator", text: field(index, "separator", fallback: ", ")) }
                            if tokens[index]["selection"]?.stringValue == "index" { TextField("Position (negative from end)", text: field(index, "index", fallback: "1")) }
                        }
                    } else if type == "attributeDate" {
                        TextField("Rule date attribute", text: field(index, "source"))
                        TextField("yyyy-MM-dd", text: field(index, "value", fallback: "yyyy-MM-dd"))
                    } else if type == "capture" {
                        Picker("Captured value", selection: field(index, "value")) {
                            Text("Choose capture").tag("")
                            ForEach(captures, id: \.self) { name in
                                Text(name.replacingOccurrences(of: "hazelcustomtoken:", with: "")).tag(name)
                            }
                        }.labelsHidden()
                    } else if type == "date" {
                        Picker("Date source", selection: field(index, "source", fallback: "dateAdded")) {
                            Text("Added").tag("dateAdded")
                            Text("Created").tag("dateCreated")
                            Text("Modified").tag("dateModified")
                            Text("Current").tag("currentDate")
                            Text("Taken").tag("hazelbuiltin:dateTaken")
                        }.labelsHidden()
                        TextField("yyyy-MM-dd", text: field(index, "value", fallback: "yyyy-MM-dd"))
                    } else if type == "counter" {
                        Picker("Format", selection: field(index, "numberFormat", fallback: "numeric")) {
                            Text("1, 2, 3").tag("numeric"); Text("a, b, c").tag("lowercase"); Text("A, B, C").tag("uppercase")
                        }.labelsHidden()
                        if (tokens[index]["numberFormat"]?.stringValue ?? "numeric") == "numeric" { TextField("Minimum digits", text: field(index, "digits", fallback: "0")) }
                        if action.kind == .rename {
                            Picker("Allocation", selection: field(index, "allocation", fallback: "increment")) {
                                Text("Always increment").tag("increment"); Text("Lowest available").tag("lowest")
                            }.labelsHidden()
                        }
                        Text("Uses this folder’s counter").font(.caption).foregroundStyle(ForelTheme.secondaryText)
                    }
                    if type == "date" || type == "attributeDate" || (type == "spotlight" && tokens[index]["valueType"]?.stringValue == "date") {
                        ForEach([("adjustYears", "Y"), ("adjustMonths", "M"), ("adjustDays", "D"), ("adjustHours", "h"), ("adjustMinutes", "m")], id: \.0) { key, label in
                            TextField(label, text: field(index, key, fallback: "0"))
                                .frame(width: 34).help("Adjust by \(label); use a negative number to subtract")
                        }
                    }
                    if type != "counter" && type != "pathSeparator" {
                        Picker("Case", selection: field(index, "case", fallback: "none")) {
                            Text("Original").tag("none"); Text("Title").tag("title")
                            Text("lowercase").tag("lower"); Text("UPPERCASE").tag("upper")
                        }.labelsHidden().frame(width: 100)
                    }
                    Button { remove(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).help("Remove token")
                }
                if tokens[index]["type"]?.stringValue != "pathSeparator" {
                    DisclosureGroup("Advanced text options") {
                        HStack {
                            TextField("Default when empty or unavailable", text: field(index, "defaultValue"))
                            TextField("Maximum characters (blank = unlimited)", text: field(index, "maxLength"))
                        }
                        HStack {
                            TextField("Numeric adjustment", text: field(index, "numericAdjustment"))
                            TextField("Minimum numeric digits", text: field(index, "minimumDigits"))
                            TextField("Thousands separator", text: field(index, "groupingSeparator"))
                        }
                        if isFolder { TextField("Split this token into folders using character (optional)", text: field(index, "pathSplit")) }
                        let replacements = tokens[index]["replacements"]?.arrayValue ?? []
                        ForEach(Array(replacements.indices), id: \.self) { replacementIndex in
                            HStack {
                                TextField("Find", text: replacementField(index, replacementIndex, "find"))
                                TextField("Replace with", text: replacementField(index, replacementIndex, "replace"))
                                Toggle("Regex", isOn: replacementRegex(index, replacementIndex))
                                Button { removeReplacement(index, replacementIndex) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            }
                        }
                        Button("Add replacement") { addReplacement(index) }.buttonStyle(.link)
                        Text("Default, numeric format, replacements in order, case, then maximum length. Numeric options require a number.").font(.caption).foregroundStyle(ForelTheme.secondaryText)
                    }
                }
                }
            }
            Button("Add token") { add() }.buttonStyle(.link)
        }
    }

    private func field(_ index: Int, _ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: {
            guard tokens.indices.contains(index) else { return fallback }
            return tokens[index][key]?.stringValue ?? fallback
        }, set: { value in
            var items = tokens
            guard items.indices.contains(index), case .object(var token) = items[index] else { return }
            token[key] = key == "case" && value == "none" ? nil : .string(value)
            if key == "selection", value == "index", token["index"] == nil { token["index"] = .string("1") }
            if key == "valueType", value == "date" { token["value"] = .string("yyyy-MM-dd") }
            if key == "type" {
                token["value"] = .string(value == "date" ? "yyyy-MM-dd" : "")
                token["source"] = value == "date" ? .string("dateAdded") : nil
                token["valueType"] = value == "spotlight" ? .string("text") : nil
                token["digits"] = value == "counter" ? .string("0") : nil
                token["numberFormat"] = value == "counter" ? .string("numeric") : nil
                token["allocation"] = value == "counter" ? .string("increment") : nil
                token["selection"] = value == "attributeList" ? .string("all") : nil
                token["separator"] = value == "attributeList" ? .string(", ") : nil
                token["adjustment"] = value == "attributeNumber" ? .string("0") : nil
                for adjustment in ["adjustYears", "adjustMonths", "adjustDays", "adjustHours", "adjustMinutes"] { token[adjustment] = nil }
                token["case"] = nil
            }
            items[index] = .object(token)
            save(items)
        })
    }

    private func updateReplacement(_ index: Int, _ replacementIndex: Int, change: (inout [String: JSONValue]) -> Void) {
        var items = tokens
        guard items.indices.contains(index), case .object(var token) = items[index], var replacements = token["replacements"]?.arrayValue,
              replacements.indices.contains(replacementIndex), case .object(var replacement) = replacements[replacementIndex] else { return }
        change(&replacement); replacements[replacementIndex] = .object(replacement); token["replacements"] = .array(replacements)
        items[index] = .object(token); save(items)
    }
    private func replacementField(_ index: Int, _ replacementIndex: Int, _ key: String) -> Binding<String> {
        Binding(get: { (tokens.indices.contains(index) ? tokens[index]["replacements"]?.arrayValue : nil).flatMap { $0.indices.contains(replacementIndex) ? $0[replacementIndex][key]?.stringValue : nil } ?? "" }, set: { value in
            updateReplacement(index, replacementIndex) { $0[key] = .string(value) }
        })
    }
    private func replacementRegex(_ index: Int, _ replacementIndex: Int) -> Binding<Bool> {
        Binding(get: { (tokens.indices.contains(index) ? tokens[index]["replacements"]?.arrayValue : nil).flatMap { $0.indices.contains(replacementIndex) ? $0[replacementIndex]["regex"]?.boolValue : nil } ?? false }, set: { value in
            updateReplacement(index, replacementIndex) { $0["regex"] = .bool(value) }
        })
    }
    private func addReplacement(_ index: Int) {
        var items = tokens; guard items.indices.contains(index), case .object(var token) = items[index] else { return }
        var replacements = token["replacements"]?.arrayValue ?? []
        replacements.append(.object(["find": .string(""), "replace": .string(""), "regex": .bool(false)]))
        token["replacements"] = .array(replacements); items[index] = .object(token); save(items)
    }
    private func removeReplacement(_ index: Int, _ replacementIndex: Int) {
        var items = tokens; guard items.indices.contains(index), case .object(var token) = items[index], var replacements = token["replacements"]?.arrayValue,
              replacements.indices.contains(replacementIndex) else { return }
        replacements.remove(at: replacementIndex); token["replacements"] = .array(replacements); items[index] = .object(token); save(items)
    }

    private func save(_ items: [JSONValue]) {
        guard case .object(var params) = action.params else { return }
        params["hazel_pattern_tokens"] = .array(items)
        action.params = .object(params)
    }
    private func remove(_ index: Int) {
        var items = tokens
        guard items.indices.contains(index) else { return }
        items.remove(at: index); save(items)
    }
    private func add() {
        var items = tokens
        let token: JSONValue = .object(["type": .string("literal"), "value": .string("")])
        if items.last?["type"]?.stringValue == "extensionIfMissing" { items.insert(token, at: items.count - 1) }
        else { items.append(token) }
        save(items)
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
