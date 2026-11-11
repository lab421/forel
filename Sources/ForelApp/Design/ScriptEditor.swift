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

/// Multi-line editor for Run Script actions: a monospaced text view with
/// line numbers and shell syntax colouring, where typing never turns quotes
/// or dashes into typographic ones. Its height is dragged from the bottom
/// edge (and remembered), and it can open in a larger window.
struct ScriptEditor: View {
    @Binding var script: String
    var placeholder: LocalizedStringKey = "Bash script — the matched file's path is in $FOREL_FILE"
    @AppStorage("scriptEditorHeight") private var height: Double = 150
    @StateObject private var controller = ScriptEditorController()
    @State private var syntaxError: String?
    @State private var showsLargeEditor = false
    @State private var dragStartHeight: Double?

    private static let minHeight: Double = 72
    private static let maxHeight: Double = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                CodeTextView(text: $script, controller: controller)
                    .overlay(alignment: .topLeading) {
                        if script.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(ForelTheme.secondaryText.opacity(0.7))
                                .padding(.leading, CodeTextView.gutterWidth + 6)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: height)
                resizeHandle
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(syntaxError == nil ? ForelTheme.surfaceBorder : ForelTheme.danger.opacity(0.6))
            )

            footer
        }
        .task(id: script) { await checkSyntax() }
        .sheet(isPresented: $showsLargeEditor) {
            LargeScriptEditor(script: $script, syntaxError: syntaxError)
        }
    }

    /// A grip along the bottom edge: drag it to make the editor taller.
    private var resizeHandle: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Capsule()
                .fill(ForelTheme.secondaryText.opacity(0.35))
                .frame(width: 36, height: 4)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartHeight ?? height
                    dragStartHeight = start
                    height = min(Self.maxHeight, max(Self.minHeight, start + value.translation.height))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
        .help("Drag to resize the editor")
        .accessibilityLabel("Resize script editor")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Insert $FOREL_FILE") { controller.insert("\"$FOREL_FILE\"") }
                .buttonStyle(SecondaryButtonStyle())
                .help("Insert the quoted path of the matched file at the cursor")
            SyntaxStatus(error: syntaxError)
            Spacer(minLength: 8)
            Text(lineCountLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(ForelTheme.secondaryText)
            Button {
                showsLargeEditor = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(IconButtonStyle())
            .help("Open in a larger editor")
            .accessibilityLabel("Open in a larger editor")
        }
    }

    private var lineCountLabel: String {
        let lines = script.isEmpty ? 0 : script.split(separator: "\n", omittingEmptySubsequences: false).count
        return String(localized: "\(lines) lines", comment: "Length of a script")
    }

    private func checkSyntax() async {
        // Wait for typing to pause before asking bash.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        let current = script
        let error = await Task.detached(priority: .utility) { ScriptSyntax.error(in: current) }.value
        guard !Task.isCancelled else { return }
        syntaxError = error
    }
}

/// Bash's syntax error under the editor; nothing when the script is valid.
private struct SyntaxStatus: View {
    let error: String?

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(ForelTheme.danger)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(error)
        }
    }
}

/// The same script in a large, freely resizable window.
private struct LargeScriptEditor: View {
    @Binding var script: String
    let syntaxError: String?
    @StateObject private var controller = ScriptEditorController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewHeader(title: "Script", subtitle: "Runs once per matching file, with its path in $FOREL_FILE", systemImage: "terminal")
            CodeTextView(text: $script, controller: controller)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ForelTheme.surface))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ForelTheme.surfaceBorder))
            HStack(spacing: 8) {
                Button("Insert $FOREL_FILE") { controller.insert("\"$FOREL_FILE\"") }
                    .buttonStyle(SecondaryButtonStyle())
                SyntaxStatus(error: syntaxError)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 560, idealWidth: 860, maxWidth: .infinity, minHeight: 360, idealHeight: 620, maxHeight: .infinity)
        .background(ForelTheme.background)
    }
}

/// Lets SwiftUI buttons act on the text view, e.g. insert at the cursor.
@MainActor
final class ScriptEditorController: ObservableObject {
    weak var textView: NSTextView?

    func insert(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}

/// AppKit text view configured for code.
struct CodeTextView: NSViewRepresentable {
    static let gutterWidth: CGFloat = 34

    @Binding var text: String
    let controller: ScriptEditorController

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                              height: CGFloat.greatestFiniteMagnitude))
        // Long lines scroll sideways instead of wrapping, like in a code editor.
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = ScriptTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize), textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.font = ScriptHighlighter.font
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.setAccessibilityLabel("Script")
        textView.delegate = context.coordinator
        textView.string = text
        ScriptHighlighter.highlight(textView)

        scrollView.documentView = textView
        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(of: scrollView, ruler: ruler)

        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        // Only replace the text when it changed elsewhere (e.g. the larger
        // editor), so typing keeps its cursor and undo history.
        if textView.string != text {
            textView.string = text
            ScriptHighlighter.highlight(textView)
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var observer: NSObjectProtocol?

        init(text: Binding<String>) {
            self.text = text
        }

        func observeScrolling(of scrollView: NSScrollView, ruler: NSRulerView) {
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak ruler] _ in
                MainActor.assumeIsolated { ruler?.needsDisplay = true }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            ScriptHighlighter.highlight(textView)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }
    }
}

/// Keeps the indentation of the current line when Return is pressed.
private final class ScriptTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// Line numbers in a gutter on the left of the text view.
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = CodeTextView.gutterWidth
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let string = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // Number of the first visible line: one more than the newlines before it.
        var line = 1 + string.substring(to: characters.location).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }

        func draw(_ number: Int, atY y: CGFloat, height: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let origin = convert(NSPoint(x: 0, y: y + textView.textContainerInset.height), from: textView)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: origin.y + (height - size.height) / 2),
                       withAttributes: attributes)
        }

        var index = characters.location
        while index < NSMaxRange(characters) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            draw(line, atY: fragment.minY, height: fragment.height)
            line += 1
            index = NSMaxRange(lineRange)
        }
        // The empty last line after a trailing newline, or an empty script.
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fragment = layoutManager.extraLineFragmentRect
            if fragment.intersects(visible) || string.length == 0 {
                draw(line, atY: fragment.minY, height: fragment.height)
            }
        }
    }
}

/// Minimal shell colouring: keywords, strings, variables and comments.
@MainActor
enum ScriptHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(if|then|else|elif|fi|for|in|do|done|while|until|case|esac|function|return|local|export|exit|break|continue|select|time)\b"#
    )
    private static let strings = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"|'[^']*'"#)
    private static let variables = try! NSRegularExpression(pattern: #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*$!-]"#)
    private static let comments = try! NSRegularExpression(pattern: #"(?m)(?:^|(?<=\s))#.*$"#)

    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        let text = storage.string
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: range)
        color(keywords, .systemPink, in: text, storage: storage, bold: true)
        color(strings, .systemRed, in: text, storage: storage)
        color(variables, .systemTeal, in: text, storage: storage)
        color(comments, .secondaryLabelColor, in: text, storage: storage)
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }

    private static func color(_ expression: NSRegularExpression, _ color: NSColor, in text: String,
                              storage: NSTextStorage, bold: Bool = false) {
        let range = NSRange(location: 0, length: (text as NSString).length)
        for match in expression.matches(in: text, range: range) {
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
            if bold {
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), range: match.range)
            }
        }
    }
}
