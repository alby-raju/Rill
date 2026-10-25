import SwiftUI
import AppKit
import RillCore

struct CodeEditor: View {
    @Binding var text: String
    var contentType: String
    var completions: [String]
    var label = "Request body editor"
    @AppStorage("editorFontSize") private var fontSize = 12.0
    @AppStorage("editorWrap") private var wrap = true
    @ViewState<String> private var query = ""
    @ViewState<Int> private var searchStep = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Find in body", text: $query).textFieldStyle(RillTextFieldStyle()).frame(maxWidth: 220).onSubmit { searchStep += 1 }
                Button { searchStep += 1 } label: { Image(systemName: "chevron.down") }.help("Find next").accessibilityLabel("Find next match")
                Spacer()
                Toggle("Wrap", isOn: $wrap).toggleStyle(.checkbox)
                Button("A−") { fontSize = max(10, fontSize - 1) }.help("Decrease editor text size").accessibilityLabel("Decrease editor text size")
                Button("A+") { fontSize = min(26, fontSize + 1) }.help("Increase editor text size").accessibilityLabel("Increase editor text size")
            }.font(.caption).padding(10).background(RillPalette.surface)
            Divider()
            NativeCodeEditor(text: $text, contentType: contentType, fontSize: fontSize, wrap: wrap, query: query, searchStep: searchStep, completions: completions)
                .accessibilityLabel(label)
        }.background(RillPalette.canvas, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(RillPalette.line))
            .buttonStyle(RillButtonStyle(emphasis: .quiet))
    }
}

private struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    let contentType: String
    let fontSize: Double
    let wrap: Bool
    let query: String
    let searchStep: Int
    let completions: [String]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        let view = CompletionTextView(frame: .zero)
        view.isRichText = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.drawsBackground = false; view.textContainerInset = NSSize(width: 10, height: 10)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.delegate = context.coordinator
        scroll.documentView = view
        let ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = view; scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.view = view
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.view else { return }
        if view.string != text {
            coordinator.applying = true
            let range = NSRange(location: 0, length: (view.string as NSString).length)
            view.insertText(text, replacementRange: range)
            coordinator.applying = false
        }
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.typingAttributes = [.font: view.font!, .foregroundColor: NSColor.textColor]
        view.isHorizontallyResizable = !wrap
        view.textContainer?.widthTracksTextView = wrap
        view.textContainer?.containerSize = NSSize(width: wrap ? max(100, scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = !wrap
        if wrap { view.setFrameSize(NSSize(width: max(100, scroll.contentSize.width), height: max(scroll.contentSize.height, view.frame.height))) }
        coordinator.highlight()
        if coordinator.lastSearch != searchStep {
            coordinator.lastSearch = searchStep
            let string = view.string as NSString, length = string.length
            let start = min(NSMaxRange(view.selectedRange()), length)
            var range = string.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: length - start))
            if range.location == NSNotFound { range = string.range(of: query, options: .caseInsensitive) }
            if !query.isEmpty && range.location != NSNotFound { view.setSelectedRange(range); view.scrollRangeToVisible(range) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditor
        weak var view: NSTextView?
        var applying = false
        var lastSearch = 0
        init(_ parent: NativeCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !applying, let view else { return }
            parent.text = view.string
            highlight()
        }
        func highlight() {
            guard let view, let storage = view.textStorage else { return }
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular), .foregroundColor: NSColor.textColor], range: range)
            if view.string.utf8.count <= 1024 * 1024 {
                var rules: [(String, NSColor)] = []
                if parent.contentType.contains("json") {
                    rules = [(#"\"(?:\\.|[^\"\\])*\""#, .systemGreen), (#"\b(?:true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#, .systemOrange)]
                } else if parent.contentType.contains("xml") { rules = [(#"</?[^>]+>"#, .systemBlue), (#"\"[^\"]*\""#, .systemGreen)] }
                else if parent.contentType.contains("form") { rules = [(#"(?:^|&)[^=&]+(?==)"#, .systemBlue)] }
                rules.append((#"\{\{[^{}]+\}\}"#, .systemTeal))
                for (pattern, color) in rules {
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        for match in regex.matches(in: view.string, range: range) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
                    }
                }
            }
            storage.endEditing()
            view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: charRange).lowercased()
            let source = textView.string as NSString
            let hasOpening = charRange.location >= 2 && source.substring(with: NSRange(location: charRange.location - 2, length: 2)) == "{{"
            let end = NSMaxRange(charRange)
            let hasClosing = end + 2 <= source.length && source.substring(with: NSRange(location: end, length: 2)) == "}}"
            return parent.completions.filter { $0.lowercased().hasPrefix(prefix) || $0.lowercased().hasPrefix("{{" + prefix) }.map { value in
                var result = value
                if hasOpening && result.hasPrefix("{{") { result.removeFirst(2) }
                if hasClosing && result.hasSuffix("}}") { result.removeLast(2) }
                return result
            }
        }
    }
}

private final class CompletionTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control { complete(nil) }
        else { super.keyDown(with: event) }
    }
}

private final class LineNumberRuler: NSRulerView {
    override var requiredThickness: CGFloat { 44 }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let visible = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let string = view.string as NSString
        let font = view.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        layout.enumerateLineFragments(forGlyphRange: visible) { frame, _, _, glyphRange, _ in
            let index = layout.characterIndexForGlyph(at: glyphRange.location)
            guard string.lineRange(for: NSRange(location: index, length: 0)).location == index else { return }
            let number = String(string.substring(to: index).filter { $0 == "\n" }.count + 1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let size = number.size(withAttributes: attributes)
            let y = frame.minY + view.textContainerOrigin.y - (view.enclosingScrollView?.contentView.bounds.minY ?? 0)
            number.draw(at: NSPoint(x: 36 - size.width, y: y), withAttributes: attributes)
        }
    }
}

struct SplitAutosave: NSViewRepresentable {
    let name: String
    let vertical: Bool
    func makeNSView(context: Context) -> SplitProbe { SplitProbe(name: name, vertical: vertical) }
    func updateNSView(_ view: SplitProbe, context: Context) { view.attach() }
    final class SplitProbe: NSView {
        let name: String; let vertical: Bool
        init(name: String, vertical: Bool) { self.name = name; self.vertical = vertical; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() {
            guard !RillPreview.isRendering else { return }
            var ancestor = superview
            while let current = ancestor {
                if let split = current as? NSSplitView, split.isVertical == vertical {
                    if split.autosaveName == nil { split.autosaveName = NSSplitView.AutosaveName(name) }
                    return
                }
                ancestor = current.superview
            }
        }
    }
}
