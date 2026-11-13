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
    @State private var errorDismissTask: Task<Void, Never>?
    @State private var upgradeContext: ProUpgradeContext?
    @EnvironmentObject private var model: AppModel
    @State private var isWide = false
    /// Shared with the card's own toggle: closed until the user opens it,
    /// then remembered.
    @AppStorage(RuleMatchPreviewCard.expandedKey) private var previewExpanded = false

    /// From this width, the matching files get their own column.
    private static let wideLayoutWidth: CGFloat = 1000
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
                title: rule.name.isEmpty ? L10n.string("new_rule") : L10n.string("rule_editor_edit_rule"),
                subtitle: L10n.string("rule_editor_conditions_decide_which_files"),
                systemImage: "slider.horizontal.3"
            )
            if showValidationErrors, !validationMessages.isEmpty {
                RuleValidationBanner(messages: validationMessages)
            }

            HStack(alignment: .top, spacing: 18) {
                ScrollView { sections }
                    .scrollIndicators(.never)
                if isWide, previewExpanded {
                    ScrollView { RuleMatchPreviewCard(rule: rule) }
                        .scrollIndicators(.never)
                        .frame(width: 360)
                }
            }
            if !(isWide && previewExpanded) {
                RuleMatchPreviewCard(rule: rule, listMaxHeight: 190)
            }

            Divider().overlay(ForelTheme.divider)

            HStack {
                Toggle(L10n.string("enabled"), isOn: $rule.enabled)
                    .toggleStyle(.switch)
                    .tint(ForelTheme.accent)
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
                Spacer()
                Button(L10n.string("cancel"), action: onCancel).buttonStyle(SecondaryButtonStyle())
                Button(L10n.string("save")) {
                    if hasValidationErrors {
                        showValidationErrors = true
                        errorDismissTask?.cancel()
                        errorDismissTask = Task {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled else { return }
                            showValidationErrors = false
                        }
                    } else {
                        if !model.isPro, rule.enabled, let feature = FreePlan.requiredFeature(for: rule) {
                            upgradeContext = .feature(feature)
                            return
                        }
                        showValidationErrors = false
                        errorDismissTask?.cancel()
                        onSave(rule)
                    }
                }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ForelTheme.background)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideLayoutWidth } action: { isWide = $0 }
        .sheet(item: $upgradeContext) { context in ProUpgradeView(context: context) }
        // Lets the main window tell whether leaving would lose changes.
        .onAppear { model.editingDraft = rule }
        .onChange(of: rule) { _, draft in model.editingDraft = draft }
    }

    /// Conditions, scope and actions; the matching files sit beside them in a
    /// wide window, below them otherwise.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel(title: L10n.string("rule_editor_basics"))
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    GlassField(placeholder: L10n.string("rule_editor_rule_name"), text: $rule.name)
                    ScopeEditor(depth: $rule.recursionDepth)

                    Picker("", selection: $rule.conditionMatch) {
                        Text(L10n.string("rule_editor_match_all_conditions")).tag(ConditionMatch.all)
                        Text(L10n.string("rule_editor_match_any_condition")).tag(ConditionMatch.any)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .padding(18)
            }

            HStack {
                SectionLabel(title: L10n.string("rule_editor_conditions"))
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
                        placeholder(L10n.string("rule_editor_conditions_rule_matches_every"))
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
                SectionLabel(title: L10n.string("rule_editor_actions"))
                Text(verbatim: "\(rule.actions.count)")
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
                        placeholder(L10n.string("rule_editor_actions_yet_add_least"))
                    }
                    ForEach($rule.actions, id: \.id) { $action in
                        ActionRow(action: $action, onRequestUpgrade: { upgradeContext = .feature($0) }) {
                            rule.actions.removeAll { $0.id == action.id }
                        }
                    }
                }
                .padding(18)
            }

        }
    }

    private var conditionIssues: [RuleValidator.Issue] {
        RuleValidator.validate(rule.conditions)
    }

    private var actionIssues: [RuleValidator.Issue] {
        RuleValidator.validate(rule.actions)
    }

    private var validationMessages: [String] {
        (conditionIssues + actionIssues).map(\.message)
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

/// Why a rule being edited can't be saved yet, as the editor reports it.
enum RuleEditorDraftCheck {
    static func problems(_ rule: Rule) -> [String] {
        var problems: [String] = []
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(L10n.string("rule_editor_rule_needs_name"))
        }
        problems += (RuleValidator.validate(rule.conditions) + RuleValidator.validate(rule.actions)).map(\.message)
        return problems
    }
}

private struct RuleValidationBanner: View {
    let messages: [String]

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
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.danger.opacity(0.24)))
    }
}

/// The items of the folder this rule would act on right now, recomputed a
/// moment after each edit so the effect of a condition shows before saving.
/// Uses the same matching and planning as Dry Run and never changes a file.
/// Collapsed by default to just its header; once opened it stays open.
private struct RuleMatchPreviewCard: View {
    static let expandedKey = "ruleMatchPreviewExpanded"

    @EnvironmentObject private var model: AppModel
    let rule: Rule
    /// Caps the list's height (it scrolls past it) where the card sits under
    /// the editor; `nil` lets it grow, e.g. in its own column.
    var listMaxHeight: CGFloat? = nil
    @AppStorage(expandedKey) private var isExpanded = false
    @State private var summary: RuleMatchSummary?
    @State private var isScanning = false

    private static let shownLimit = 8
    private static let scanLimit = 5_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                if let listMaxHeight {
                    ScrollView { card }
                        .scrollIndicators(.automatic)
                        .frame(maxHeight: listMaxHeight)
                } else {
                    card
                }
            }
        }
        .task(id: rule) { await refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    SectionLabel(title: L10n.string("rule_editor_matching_files"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? L10n.string("rule_editor_hide_the_matching_files") : L10n.string("rule_editor_show_files_rule_matches"))
            .accessibilityLabel(L10n.string("rule_editor_matching_files"))
            .accessibilityValue(isExpanded ? L10n.string("rule_editor_expanded") : L10n.string("rule_editor_collapsed"))
            if isScanning { ProgressView().controlSize(.small) }
            Spacer()
            if let summary, !needsPro {
                Text(checkedLabel(summary))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ForelTheme.secondaryText)
            }
        }
    }

    private var card: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    @ViewBuilder private var content: some View {
        if needsPro {
            note(L10n.string("rule_editor_rule_uses_forel_pro"))
        } else if let summary {
            if summary.total == 0 {
                note(summary.isComplete
                     ? L10n.string("rule_editor_nothing_folder_matches_right")
                     : L10n.plural("rule_editor_nothing_matches_first_items", summary.checked))
            } else {
                Text(matchLabel(summary))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ForelTheme.primaryText)
                if let sharedNote = sharedNote(summary) {
                    Label(sharedNote, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                let shown = Array(summary.matches.prefix(Self.shownLimit))
                ForEach(shown) { match in
                    row(match, showsAction: sharedNote(summary) == nil)
                }
                if summary.total > shown.count {
                    Text(summary.isComplete ? L10n.plural("rule_editor_and_more_count", summary.total - shown.count) : L10n.string("rule_editor_and_more"))
                        .font(.caption)
                        .foregroundStyle(ForelTheme.secondaryText)
                }
            }
            note(L10n.string("rule_editor_only_rule_checked_use"))
                .font(.caption)
        } else {
            note(L10n.string("rule_editor_checking_items_folder"))
        }
    }

    private func row(_ match: RuleMatchSummary.Match, showsAction: Bool) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: match.path))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(match.name)
                .foregroundStyle(ForelTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if showsAction, let text = match.warning ?? match.action {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(match.warning == nil && match.wouldRun ? ForelTheme.secondaryText : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(text)
            }
        }
        .font(.system(size: 13))
        .help(match.path)
        .contextMenu {
            Button(L10n.string("show_in_finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: match.path)])
            }
            Button(L10n.string("rule_editor_copy_path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(match.path, forType: .string)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(ForelTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One message instead of the same one on every row: the actions are
    /// incomplete, or every listed file hits the same problem.
    private func sharedNote(_ summary: RuleMatchSummary) -> String? {
        if rule.actions.isEmpty { return L10n.string("rule_editor_add_action_see_what") }
        if !RuleValidator.validate(rule.actions).isEmpty { return L10n.string("rule_editor_complete_actions_above_see") }
        let warnings = Set(summary.matches.prefix(Self.shownLimit).map(\.warning))
        if warnings.count == 1, let warning = warnings.first ?? nil { return warning }
        return nil
    }

    private func matchLabel(_ summary: RuleMatchSummary) -> String {
        summary.isComplete
            ? L10n.plural("rule_editor_items_match", summary.total)
            : L10n.plural("rule_editor_at_least_items_match", summary.total)
    }

    private func checkedLabel(_ summary: RuleMatchSummary) -> String {
        summary.isComplete
            ? L10n.plural("rule_editor_items_checked", summary.checked)
            : L10n.plural("rule_editor_first_items_checked", summary.checked)
    }

    private var needsPro: Bool {
        !model.isPro && FreePlan.requiredFeature(for: rule) != nil
    }

    private func refresh() async {
        // Wait for typing to pause before reading the folder again.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled, !needsPro,
              let folder = model.folders.first(where: { $0.id == rule.folderId }) else { return }
        let draft = rule
        let isPro = model.isPro
        let scanLimit = Self.scanLimit
        isScanning = true
        defer { isScanning = false }
        let work = Task.detached(priority: .userInitiated) {
            RuleEngine.previewMatches(of: draft, root: folder.path, isPro: isPro, scanLimit: scanLimit) {
                Task.isCancelled
            }
        }
        let computed = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        summary = computed
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
                Text(L10n.string("rule_editor_scope")).font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                Spacer()
                Picker("", selection: modeBinding) {
                    Text(L10n.string("rule_editor_current_folder")).tag(0)
                    Text(L10n.string("rule_editor_subfolders")).tag(1)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            if depth != 0 {
                HStack(spacing: 10) {
                    Text(L10n.string("rule_editor_depth")).font(.system(size: 12)).foregroundStyle(ForelTheme.secondaryText)
                    GlassField(placeholder: "1", text: depthTextBinding)
                        .frame(width: 72)
                        .disabled(depth == nil)
                    Toggle(L10n.string("rule_editor_all_levels"), isOn: allLevelsBinding)
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
                        Text(L10n.string("rule_editor_all_levels_slow_execution"))
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
        guard let depth else { return L10n.string("rule_editor_all_subfolder_levels") }
        return L10n.plural("rule_editor_subfolder_levels", Int(max(1, depth)))
    }
}

private struct ConditionRow: View {
    @Binding var condition: Condition
    @EnvironmentObject private var model: AppModel
    let onRequestUpgrade: (ProFeature) -> Void
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
            if condition.kind == .contents, !model.isPro {
                HStack {
                    Text(L10n.string("rule_editor_document_text_included_free"))
                        .font(.caption)
                        .foregroundStyle(ForelTheme.secondaryText)
                    Button(L10n.string("rule_editor_unlock_ocr")) { onRequestUpgrade(.ocr) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder private var conditionValue: some View {
        switch RuleSchema.valueKind(for: condition.kind, operator: condition.operator) {
        case .none:
            Spacer(minLength: 0)
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
            GlassField(placeholder: L10n.string("rule_editor_value"), text: $condition.value)
        }
    }

    private var rowHelpText: String? {
        if condition.kind == .kind, condition.value == "archive" {
            return L10n.string("rule_editor_archive_matches_compressed_formats")
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
                                        Label(L10n.string("pro"), systemImage: "lock.fill")
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
                                    Label(L10n.string("pro"), systemImage: "lock.fill")
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
            return L10n.string("rule_editor_invalid_regular_expression")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassField(placeholder: L10n.string("rule_editor_regex_pattern"), text: $value)
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
    private let units = ["hours", "days", "weeks", "months", "years"]

    var body: some View {
        HStack(spacing: 8) {
            GlassField(placeholder: "7", text: numberBinding)
                .frame(width: 72)
            StringSelectMenu(selection: unitBinding, options: units, label: Self.unitLabel)
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

    /// The stored value keeps the English unit ("7 days"): the engine reads it.
    private static func unitLabel(_ unit: String) -> String {
        switch unit {
        case "hours": L10n.string("rule_editor_hours")
        case "days": L10n.string("rule_editor_days")
        case "weeks": L10n.string("rule_editor_weeks")
        case "months": L10n.string("rule_editor_months")
        case "years": L10n.string("rule_editor_years")
        default: unit
        }
    }

    private var parts: (number: String, unit: String) {
        // omittingEmptySubsequences: false keeps "" as the number when the
        // field is transiently empty mid-edit, so the unit survives keystrokes.
        let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let number = pieces.first?.filter(\.isNumber)
        let unit = pieces.count > 1 ? pieces[1] : "days"
        return ((number?.isEmpty == false ? number! : "7"), units.contains(unit) ? unit : "days")
    }
}

private struct SizeValueEditor: View {
    @Binding var value: String

    var body: some View {
        HStack(spacing: 8) {
            GlassField(placeholder: "0", text: numberBinding)
                .frame(width: 90)
            StringSelectMenu(selection: unitBinding, options: ["bytes", "KB", "MB", "GB"], label: Self.unitLabel)
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

    /// The stored value keeps the English unit ("10 MB"): the engine reads it.
    private static func unitLabel(_ unit: String) -> String {
        switch unit {
        case "bytes": L10n.string("rule_editor_bytes")
        case "KB": L10n.string("rule_editor_kb")
        case "MB": L10n.string("rule_editor_mb")
        case "GB": L10n.string("rule_editor_gb")
        default: unit
        }
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
                TextField(L10n.string("rule_editor_app_name"), text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(ForelTheme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))

            Button(L10n.string("choose"), action: choose).buttonStyle(SecondaryButtonStyle())
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
                TextField(L10n.string("application"), text: $path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(ForelTheme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))

            Button(L10n.string("choose"), action: choose).buttonStyle(SecondaryButtonStyle())
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
            label: { value in FileKindCatalog.label(for: value) }
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ActionKindMenu(selection: kindBinding, onRequestUpgrade: onRequestUpgrade)
            .frame(minWidth: 160, alignment: .leading)

            Group {
                if !model.isPro, let feature = FreePlan.requiredFeature(for: action.kind) {
                    Button(L10n.string("rule_editor_unlock", feature.title)) { onRequestUpgrade(feature) }
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
                .help(L10n.string("rule_editor_action_options"))
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
            FolderField(
                placeholder: L10n.string("rule_editor_destination_folder"),
                path: paramBinding(ActionParam.destination),
                hint: L10n.string("rule_editor_add_kind_extension_year")
            )
        case .syncFolders:
            FolderField(placeholder: L10n.string("rule_editor_destination_folder"), path: paramBinding(ActionParam.destination))
        case .rename:
            RenamePatternEditor(pattern: paramBinding(ActionParam.pattern), cleanFileName: action.params[ActionParam.cleanFileName]?.boolValue == true)
        case .addTag, .removeTag:
            TagTokensEditor(tags: tagsBinding, placeholder: action.kind == .addTag ? L10n.string("add_tag") : L10n.string("rule_editor_tag"))
        case .setColorLabel:
            ColorLabelPicker(selection: paramBinding(ActionParam.color), allowNone: true)
        case .toggleLock:
            Picker(L10n.string("rule_editor_state"), selection: boolParamBinding(ActionParam.locked)) {
                Text(L10n.string("locked")).tag(true)
                Text(L10n.string("rule_editor_unlocked")).tag(false)
            }
            .labelsHidden()
        case .toggleExtension:
            Picker(L10n.string("extension"), selection: boolParamBinding(ActionParam.extensionHidden)) {
                Text(L10n.string("rule_editor_hidden")).tag(true)
                Text(L10n.string("rule_editor_visible")).tag(false)
            }
            .labelsHidden()
        case .runScript:
            VStack(alignment: .leading, spacing: 6) {
                ScriptEditor(script: paramBinding(ActionParam.script))
                Text(L10n.string("rule_editor_runs_once_per_matching"))
                    .font(.caption)
                    .foregroundStyle(ForelTheme.secondaryText)
                    .textSelection(.enabled)
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
                    Text(L10n.string("rule_editor_library"))
                        .font(.system(size: 11))
                        .foregroundStyle(ForelTheme.secondaryText)
                        .frame(width: 52, alignment: .trailing)
                    LibraryTypePicker(selection: libTypeBinding)
                }
                if libType == .music || libType == .tv {
                    let app = libType == .music ? "Music" : "TV"
                    HStack(spacing: 6) {
                        Text(L10n.string("rule_editor_playlist"))
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                        PlaylistPicker(selection: paramBinding(ActionParam.targetPlaylist), app: app)
                            .id(app)
                    }
                } else if libType == .photos {
                    HStack(spacing: 6) {
                        Text(L10n.string("rule_editor_album"))
                            .font(.system(size: 11))
                            .foregroundStyle(ForelTheme.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                        AlbumPicker(selection: paramBinding(ActionParam.targetPlaylist))
                    }
                }
            }
        case .uncompress:
            Text(L10n.string("rule_editor_zip_archives_only"))
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .frame(minHeight: 32, alignment: .center)
        case .compress:
            ArchiveNameEditor(pattern: paramBinding(ActionParam.archiveName))
        case .moveToTrash, .delete:
            Text(L10n.string("rule_editor_no_parameters"))
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
                } else if newKind == .syncFolders {
                    params[ActionParam.syncDeletePolicy] = .string(SyncDeletePolicy.keepOtherSide.rawValue)
                } else if newKind == .openApplication {
                    params[ActionParam.passFileToApplication] = .bool(true)
                } else if newKind == .toggleLock {
                    params[ActionParam.locked] = .bool(true)
                } else if newKind == .toggleExtension {
                    params[ActionParam.extensionHidden] = .bool(true)
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

    private func boolParamBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { action.params[key]?.boolValue ?? true },
            set: { newValue in
                var dict: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { dict = existing }
                dict[key] = .bool(newValue)
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
            Text(L10n.string("rule_editor_options"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ForelTheme.primaryText)

            switch action.kind {
            case .runShortcut:
                shortcutOptions
            case .openApplication:
                openApplicationOptions
            case .moveToFolder, .copyToFolder, .importToLibrary, .uncompress:
                conflictResolutionOptions
            case .syncFolders:
                syncOptions
            case .rename:
                renameOptions
            case .compress:
                compressionOptions
            default:
                Text(L10n.string("rule_editor_options_action"))
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.secondaryText)
            }
        }
    }

    private var openApplicationOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: passFileToApplicationBinding) {
                Text(L10n.string("rule_editor_pass_matched_file_app"))
                    .font(.system(size: 12))
                    .foregroundStyle(ForelTheme.primaryText)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var compressionOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("destination"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)
            FolderField(
                placeholder: L10n.string("rule_editor_next_source_default"),
                path: paramBinding(ActionParam.destination),
                hint: L10n.string("rule_editor_supports_kind_extension_year")
            )
            if action.params[ActionParam.destination]?.stringValue?.isEmpty == false {
                Button(L10n.string("rule_editor_use_source_folder")) { paramBinding(ActionParam.destination).wrappedValue = "" }
                    .buttonStyle(.link)
            }
            Text(L10n.string("rule_editor_leave_empty_save_next"))
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(L10n.string("rule_editor_delete_source_after_compression"), isOn: deleteSourceBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12))
            if ActionExecutor.deletesSourceAfterCompression(action) {
                Label(
                    L10n.string("rule_editor_after_zip_created_successfully"),
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deleteSourceBinding: Binding<Bool> {
        Binding(
            get: { ActionExecutor.deletesSourceAfterCompression(action) },
            set: { enabled in
                var params: [String: JSONValue] = [:]
                if case .object(let existing) = action.params { params = existing }
                params[ActionParam.deleteSourceAfterCompression] = .bool(enabled)
                action.params = .object(params)
            }
        )
    }

    private var conflictResolutionOptions: some View {
        let defaultResolution = action.kind == .importToLibrary ? MoveConflictResolution.skip.rawValue : MoveConflictResolution.rename.rawValue
        let options = action.kind == .importToLibrary
            ? MoveConflictResolution.allCases.filter { $0 != .rename }.map(\.rawValue)
            : MoveConflictResolution.allCases.map(\.rawValue)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("rule_editor_if_file_already_exists"))
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
            Text(L10n.string("rule_editor_input"))
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

    private var syncOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("rule_editor_deletes"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ForelTheme.secondaryText)

            StringSelectMenu(
                selection: paramBinding(ActionParam.syncDeletePolicy, defaultValue: SyncDeletePolicy.keepOtherSide.rawValue),
                options: SyncDeletePolicy.allCases.map(\.rawValue),
                label: { value in SyncDeletePolicy(rawValue: value)?.label ?? value }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            if ActionExecutor.syncDeletePolicy(action) == .delete {
                Label(
                    L10n.string("rule_editor_when_file_deleted_watched"),
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.system(size: 11))
                    .foregroundStyle(ForelTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var renameOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: cleanNameBinding) {
                Text(L10n.string("rule_editor_clean_file_name"))
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
                GlassField(placeholder: isLoading ? L10n.string("rule_editor_loading_shortcuts") : L10n.string("rule_editor_shortcut_name"), text: $selection)
            } else {
                StringSelectMenu(selection: shortcutBinding, options: shortcutOptions)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: loadShortcuts) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help(L10n.string("rule_editor_refresh_shortcuts"))
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
                label: { $0.isEmpty ? L10n.string("rule_editor_none") : $0 }
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
                label: { $0.isEmpty ? L10n.string("rule_editor_none") : $0 }
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
                names.append(collection.localizedTitle ?? L10n.string("rule_editor_untitled"))
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
            .help(L10n.string("add_tag"))
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

private struct ArchiveNameEditor: View {
    @Binding var pattern: String

    private let tokens = [
        (value: "{name}", label: L10n.string("rule_editor_source_name")),
        (value: "{current_date}", label: L10n.string("rule_editor_current_date")),
        (value: "{timestamp}", label: L10n.string("rule_editor_timestamp")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassField(placeholder: L10n.string("rule_editor_archive_name_e_g"), text: $pattern)
                .accessibilityLabel(L10n.string("rule_editor_archive_name"))
            HStack(spacing: 6) {
                ForEach(tokens, id: \.value) { token in
                    Button(token.label) { insert(token.value) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(L10n.string("rule_editor_insert", token.value))
                }
            }
            Text(preview)
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .textSelection(.enabled)
            Text(L10n.string("rule_editor_empty_uses_name_zip"))
                .font(.system(size: 11))
                .foregroundStyle(ForelTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var preview: String {
        do {
            return L10n.string("rule_editor_preview", try ActionExecutor.archiveFileName(pattern: pattern, sourceName: "file"))
        } catch {
            return String(describing: error)
        }
    }

    private func insert(_ token: String) {
        var base = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".zip") { base = String(base.dropLast(4)) }
        let separator = base.isEmpty || base.hasSuffix("-") || base.hasSuffix("_") ? "" : "-"
        pattern = base + separator + token + ".zip"
    }
}

private struct RenamePatternEditor: View {
    @Binding var pattern: String
    let cleanFileName: Bool

    private let tokens: [(placeholder: String, label: String)] = [
        ("{name}", L10n.string("rule_editor_token_name")),
        ("{extension}", L10n.string("rule_editor_token_extension")),
        ("{date_modified}", L10n.string("rule_editor_token_date_modified")),
        ("{date_created}", L10n.string("rule_editor_token_date_created")),
        ("{current_date}", L10n.string("rule_editor_token_current_date")),
        ("{size}", L10n.string("rule_editor_token_size")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassField(placeholder: L10n.string("rule_editor_pattern_e_g_name"), text: $pattern)

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
        guard !candidate.isEmpty else { return L10n.string("rule_editor_preview", "") }
        if candidate.contains("/") {
            return L10n.string("rule_editor_pattern_contains_which_allowed")
        }
        let previewName = candidate
            .replacingOccurrences(of: "{name}", with: "file")
            .replacingOccurrences(of: "{extension}", with: "txt")
            .replacingOccurrences(of: "{current_date}", with: dateString())
        let displayName = cleanFileName ? ActionExecutor.cleanFileName(previewName) : previewName
        if displayName == "." || displayName == ".." {
            return L10n.string("rule_editor_pattern_resolves_which_valid", displayName)
        }
        if displayName.utf8.count > 255 {
            return L10n.string("rule_editor_pattern_resolves_filename_longer")
        }
        if let last = displayName.last, last == "." || last == " " {
            return L10n.string("rule_editor_pattern_resolves_trailing_space", displayName)
        }
        return L10n.string("rule_editor_preview", displayName)
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
