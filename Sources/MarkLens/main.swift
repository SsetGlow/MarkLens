import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownFile: Identifiable, Hashable {
    let id: URL
    let url: URL
    var name: String { url.lastPathComponent }
}

struct FileNode: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let file: MarkdownFile?
    var children: [FileNode]?
}

struct MarkdownHeading: Identifiable, Hashable {
    let id: String
    let title: String
    let level: Int
}

@MainActor
final class DocumentOpenStore: ObservableObject {
    static let shared = DocumentOpenStore()

    @Published var url: URL?

    private init() {}

    func open(_ url: URL) {
        self.url = url
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            DocumentOpenStore.shared.open(url)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in
            DocumentOpenStore.shared.open(URL(fileURLWithPath: filename))
        }
        return true
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var tree: [FileNode] = []
    @Published var selectedFile: MarkdownFile?
    @Published var text = ""
    @Published var status = "Ready"
    @Published var wordCount = 0

    private var saveTask: Task<Void, Never>?
    private var isLoading = false
    private let lastOpenedFileKey = "lastOpenedFilePath"

    init() {
        loadLastOpenedFile()
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder that contains Markdown files."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootURL = url
        loadFolder(url)
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]
        panel.prompt = "Open"
        panel.message = "Choose a Markdown file."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            status = "File not found"
            return
        }

        if isDirectory.boolValue {
            rootURL = url
            loadFolder(url)
            return
        }

        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            status = "Unsupported file"
            return
        }

        let folder = url.deletingLastPathComponent()
        rootURL = folder
        tree = scan(folder)
        select(MarkdownFile(id: url, url: url))
    }

    func newNote() {
        let base = rootURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let drafts = base.appendingPathComponent("MarkLens Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = drafts.appendingPathComponent("untitled-\(formatter.string(from: Date())).md")
        let body = "# Untitled\n\nStart writing here.\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        rootURL = rootURL ?? drafts
        tree = scan(rootURL ?? drafts)
        select(MarkdownFile(id: url, url: url))
    }

    func select(_ file: MarkdownFile) {
        isLoading = true
        selectedFile = file
        text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        wordCount = Self.countWords(text)
        status = "Ready"
        UserDefaults.standard.set(file.url.path, forKey: lastOpenedFileKey)
        isLoading = false
    }

    func textChanged(_ next: String) {
        text = next
        wordCount = Self.countWords(next)
        guard !isLoading else { return }
        scheduleSave()
    }

    func refreshTree() {
        if let rootURL {
            tree = scan(rootURL)
        }
    }

    private func loadFolder(_ url: URL) {
        tree = scan(url)
        if let first = firstFile(in: tree) {
            select(first)
        } else {
            selectedFile = nil
            text = "# Empty Workspace\n\nNo Markdown files were found in this folder.\n"
            status = "No Markdown files"
        }
    }

    private func scheduleSave() {
        guard let file = selectedFile else { return }
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            status = "Sample"
            return
        }
        status = "Editing"
        saveTask?.cancel()
        let contents = text
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do {
                try contents.write(to: file.url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    self?.status = "Saved"
                }
            } catch {
                await MainActor.run {
                    self?.status = "Save failed"
                }
            }
        }
    }

    private func loadLastOpenedFile() {
        guard let path = UserDefaults.standard.string(forKey: lastOpenedFileKey), !path.isEmpty else {
            selectedFile = nil
            text = ""
            wordCount = 0
            status = "Open a Markdown file"
            return
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: lastOpenedFileKey)
            selectedFile = nil
            text = ""
            wordCount = 0
            status = "Last file not found"
            return
        }

        open(url)
    }

    private func scan(_ root: URL) -> [FileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }

        return buildTree(root: root, files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    private func buildTree(root: URL, files: [URL]) -> [FileNode] {
        final class Branch {
            var children: [String: Branch] = [:]
            var files: [URL] = []
        }

        let branch = Branch()
        for file in files {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            let components = relative.split(separator: "/").map(String.init)
            var cursor = branch
            for folder in components.dropLast() {
                if cursor.children[folder] == nil {
                    cursor.children[folder] = Branch()
                }
                cursor = cursor.children[folder]!
            }
            cursor.files.append(file)
        }

        func nodes(_ branch: Branch, at url: URL) -> [FileNode] {
            let folderNodes = branch.children.keys.sorted().map { name in
                let childURL = url.appendingPathComponent(name, isDirectory: true)
                return FileNode(id: childURL, url: childURL, name: name, file: nil, children: nodes(branch.children[name]!, at: childURL))
            }
            let fileNodes = branch.files.map { file in
                FileNode(id: file, url: file, name: file.lastPathComponent, file: MarkdownFile(id: file, url: file), children: nil)
            }
            return folderNodes + fileNodes
        }

        return nodes(branch, at: root)
    }

    private func firstFile(in nodes: [FileNode]) -> MarkdownFile? {
        for node in nodes {
            if let file = node.file { return file }
            if let children = node.children, let file = firstFile(in: children) { return file }
        }
        return nil
    }

    private static func countWords(_ value: String) -> Int {
        value.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func headings(in markdown: String) -> [MarkdownHeading] {
        var headings: [MarkdownHeading] = []
        var counts: [String: Int] = [:]

        for line in markdown.components(separatedBy: .newlines) {
            guard let match = line.range(of: #"^(#{1,6})\s+(.+)$"#, options: .regularExpression) else { continue }
            let value = String(line[match])
            let level = value.prefix { $0 == "#" }.count
            let title = value.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }

            let slug = slugify(title)
            let count = counts[slug, default: 0]
            counts[slug] = count + 1
            let uniqueSlug = count == 0 ? slug : "\(slug)-\(count)"
            headings.append(MarkdownHeading(id: uniqueSlug, title: title, level: level))
        }

        return headings
    }

    private static func slugify(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        var previousWasSeparator = false

        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value >= 0x4E00 && scalar.value <= 0x9FFF || scalar == UnicodeScalar("_") || scalar == UnicodeScalar("-") {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar), !previousWasSeparator, !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct MarkLensAppView: View {
    @StateObject private var model = WorkspaceModel()
    @ObservedObject private var documentOpenStore = DocumentOpenStore.shared
    @State private var selectedHeadingID: String?

    private var headings: [MarkdownHeading] {
        WorkspaceModel.headings(in: model.text)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                topbar
                MarkdownTextView(text: $model.text, scrollTarget: selectedHeadingID, onChange: model.textChanged)
                    .id(model.selectedFile?.id)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .navigationTitle(model.selectedFile?.name ?? "Untitled")
        .frame(minWidth: 980, minHeight: 680)
        .onReceive(NotificationCenter.default.publisher(for: .markLensNewNoteCommand)) { _ in
            model.newNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markLensOpenFileCommand)) { _ in
            model.openFile()
        }
        .onAppear {
            if let url = documentOpenStore.url {
                model.open(url)
            }
        }
        .onReceive(documentOpenStore.$url.compactMap { $0 }) { url in
            model.open(url)
        }
        .onOpenURL { url in
            model.open(url)
        }
    }

    private var sidebar: some View {
        List(headings, selection: $selectedHeadingID) { heading in
            Button {
                selectedHeadingID = heading.id
            } label: {
                Text(heading.title)
                    .font(heading.level <= 2 ? .subheadline.weight(.semibold) : .subheadline)
                    .lineLimit(2)
                    .padding(.leading, CGFloat(max(heading.level - 1, 0)) * 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedHeadingID == heading.id ? .primary : .secondary)
        }
        .overlay {
            if headings.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var topbar: some View {
        HStack {
            Text(model.selectedFile?.name ?? "Untitled")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

enum EditorCommand {
    case heading1, heading2, bold, italic, code, quote, list, task, indent, outdent
}

extension Notification.Name {
    static let markLensFormatCommand = Notification.Name("MarkLensFormatCommand")
    static let markLensNewNoteCommand = Notification.Name("MarkLensNewNoteCommand")
    static let markLensOpenFileCommand = Notification.Name("MarkLensOpenFileCommand")
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var horizontalInset: CGFloat = 72
    var scrollTarget: String?
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        let textView = StableMarkdownTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: horizontalInset, height: 40)
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting()
        }
        context.coordinator.scroll(to: scrollTarget)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        private var observer: NSObjectProtocol?
        private var isApplyingHighlight = false
        private var highlightTask: Task<Void, Never>?
        private var lastActiveLine = NSRange(location: NSNotFound, length: 0)
        private var lastScrollTarget: String?
        private var pendingEditedRange: NSRange?
        private let highlighter = MarkdownHighlighter()

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            super.init()
            observer = NotificationCenter.default.addObserver(
                forName: .markLensFormatCommand,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let command = note.object as? EditorCommand else { return }
                self?.apply(command)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            highlightTask?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard !isApplyingHighlight else { return }
            parent.onChange(textView.string)
            scheduleHighlighting(in: pendingEditedRange)
            pendingEditedRange = nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingHighlight else { return }
            guard let textView else { return }
            let activeLine = currentLineRange(in: textView)
            guard !NSEqualRanges(activeLine, lastActiveLine) else { return }
            let previousLine = lastActiveLine
            let changedRange = NSUnionRange(activeLine, previousLine.location == NSNotFound ? activeLine : previousLine)
            applyHighlighting(in: changedRange, preservingViewport: true)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let nsText = textView.string as NSString
            let replacementLength = (replacementString ?? "").utf16.count
            let newLength = max(replacementLength, affectedCharRange.length)
            let editedRange = NSRange(location: affectedCharRange.location, length: newLength)
            let originalLineRange = nsText.lineRange(for: NSRange(location: min(affectedCharRange.location, nsText.length), length: 0))
            pendingEditedRange = NSUnionRange(editedRange, originalLineRange)
            return true
        }

        func applyHighlighting(preservingViewport: Bool = false) {
            applyHighlighting(in: nil, preservingViewport: preservingViewport)
        }

        private func applyHighlighting(in changedRange: NSRange?, preservingViewport: Bool = false) {
            guard let textView, let storage = textView.textStorage else { return }
            guard !isApplyingHighlight else { return }
            let updates = {
                self.isApplyingHighlight = true
                let selection = textView.selectedRanges
                let activeLine = self.currentLineRange(in: textView)
                self.lastActiveLine = activeLine
                self.highlighter.apply(to: storage, activeLine: activeLine, changedRange: changedRange)
                textView.selectedRanges = selection
                textView.typingAttributes = [
                    .font: NSFont.systemFont(ofSize: 17),
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.textBackgroundColor
                ]
                self.isApplyingHighlight = false
            }

            if preservingViewport, let stableTextView = textView as? StableMarkdownTextView {
                stableTextView.preserveViewportDuring(updates)
                return
            }

            isApplyingHighlight = true
            let selection = textView.selectedRanges
            let activeLine = currentLineRange(in: textView)
            lastActiveLine = activeLine
            highlighter.apply(to: storage, activeLine: activeLine, changedRange: changedRange)
            textView.selectedRanges = selection
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: 17),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.textBackgroundColor
            ]
            isApplyingHighlight = false
        }

        private func scheduleHighlighting(in changedRange: NSRange?) {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(35))
                guard !Task.isCancelled else { return }
                self?.applyHighlighting(in: changedRange)
            }
        }

        private func currentLineRange(in textView: NSTextView) -> NSRange {
            let nsText = textView.string as NSString
            guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }
            let selection = textView.selectedRange()
            let location = min(selection.location, max(nsText.length - 1, 0))
            return nsText.lineRange(for: NSRange(location: location, length: 0))
        }

        func scroll(to target: String?) {
            guard let target, target != lastScrollTarget, let textView else { return }
            lastScrollTarget = target

            let nsText = textView.string as NSString
            let full = NSRange(location: 0, length: nsText.length)
            var counts: [String: Int] = [:]

            nsText.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, stop in
                let line = nsText.substring(with: range)
                guard let heading = MarkdownHighlighter.heading(in: line) else { return }
                let slug = MarkdownHighlighter.slugify(heading.title)
                let count = counts[slug, default: 0]
                counts[slug] = count + 1
                let uniqueSlug = count == 0 ? slug : "\(slug)-\(count)"
                if uniqueSlug == target {
                    textView.scrollRangeToVisible(range)
                    textView.setSelectedRange(NSRange(location: range.location, length: 0))
                    textView.window?.makeFirstResponder(textView)
                    stop.pointee = true
                }
            }
        }

        private func apply(_ command: EditorCommand) {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            switch command {
            case .heading1:
                prefixCurrentLine("# ", in: textView)
            case .heading2:
                prefixCurrentLine("## ", in: textView)
            case .quote:
                prefixCurrentLine("> ", in: textView)
            case .list:
                prefixCurrentLine("- ", in: textView)
            case .task:
                prefixCurrentLine("- [ ] ", in: textView)
            case .indent:
                shiftSelectedLines(in: textView, direction: .indent)
            case .outdent:
                shiftSelectedLines(in: textView, direction: .outdent)
            case .bold:
                wrapSelection("**", in: textView)
            case .italic:
                wrapSelection("*", in: textView)
            case .code:
                wrapSelection("`", in: textView)
            }
            parent.onChange(textView.string)
            applyHighlighting(in: textView.selectedRange())
        }

        private enum IndentDirection {
            case indent
            case outdent
        }

        private func lineRange(for selectedRange: NSRange, in text: NSString) -> NSRange {
            text.lineRange(for: NSRange(location: min(selectedRange.location, text.length), length: 0))
        }

        private func prefixCurrentLine(_ prefix: String, in textView: NSTextView) {
            let nsText = textView.string as NSString
            let selected = textView.selectedRange()
            let line = lineRange(for: selected, in: nsText)
            if nsText.substring(with: line).hasPrefix(prefix) { return }
            textView.insertText(prefix, replacementRange: NSRange(location: line.location, length: 0))
        }

        private func wrapSelection(_ marker: String, in textView: NSTextView) {
            let selected = textView.selectedRange()
            if selected.length == 0 {
                textView.insertText(marker + marker, replacementRange: selected)
                textView.setSelectedRange(NSRange(location: selected.location + marker.count, length: 0))
                return
            }
            let nsText = textView.string as NSString
            let value = nsText.substring(with: selected)
            textView.insertText(marker + value + marker, replacementRange: selected)
        }

        private func shiftSelectedLines(in textView: NSTextView, direction: IndentDirection) {
            let nsText = textView.string as NSString
            let selected = textView.selectedRange()
            let lineRange = nsText.lineRange(for: selected)
            let original = nsText.substring(with: lineRange)
            let lines = original.components(separatedBy: "\n")
            let keepsTrailingNewline = original.hasSuffix("\n")
            let editableLines = keepsTrailingNewline ? Array(lines.dropLast()) : lines
            let shifted = editableLines.map { line in
                switch direction {
                case .indent:
                    return "    " + line
                case .outdent:
                    if line.hasPrefix("    ") {
                        return String(line.dropFirst(4))
                    }
                    if line.hasPrefix("\t") || line.hasPrefix(" ") {
                        return String(line.dropFirst())
                    }
                    return line
                }
            }
            var replacement = shifted.joined(separator: "\n")
            if keepsTrailingNewline {
                replacement += "\n"
            }
            textView.insertText(replacement, replacementRange: lineRange)
            textView.setSelectedRange(NSRange(location: lineRange.location, length: replacement.utf16.count))
        }
    }
}

final class StableMarkdownTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, modifiers.isSubset(of: [.shift]) {
            NotificationCenter.default.post(name: .markLensFormatCommand, object: EditorCommand.indent)
            return
        }

        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "]":
                NotificationCenter.default.post(name: .markLensFormatCommand, object: EditorCommand.indent)
                return
            case "[":
                NotificationCenter.default.post(name: .markLensFormatCommand, object: EditorCommand.outdent)
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        if insertMarkdownContinuation() {
            return
        }
        super.insertNewline(sender)
    }

    private func insertMarkdownContinuation() -> Bool {
        let selected = selectedRange()
        guard selected.length == 0 else { return false }
        let nsText = string as NSString
        guard nsText.length > 0 else { return false }
        let lineRange = nsText.lineRange(for: NSRange(location: min(selected.location, nsText.length), length: 0))
        let rawLine = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard let continuation = markdownContinuation(after: rawLine) else { return false }
        insertText("\n" + continuation, replacementRange: selected)
        return true
    }

    private func markdownContinuation(after line: String) -> String? {
        guard let match = line.range(of: #"^(\s*)((?:[-*+])|\d+[.])\s+((?:\[[ xX]\]\s+)?)"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(line[match])
        let nsMatched = matched as NSString
        let regex = try? NSRegularExpression(pattern: #"^(\s*)((?:[-*+])|\d+[.])\s+((?:\[[ xX]\]\s+)?)"#)
        guard let result = regex?.firstMatch(in: matched, range: NSRange(location: 0, length: nsMatched.length)) else { return nil }
        let indent = nsMatched.substring(with: result.range(at: 1))
        let marker = nsMatched.substring(with: result.range(at: 2))
        let checkbox = result.range(at: 3).length > 0 ? "[ ] " : ""
        let contentStart = line.index(line.startIndex, offsetBy: matched.count)
        let content = line[contentStart...].trimmingCharacters(in: .whitespaces)

        if content.isEmpty {
            let lineLength = (line as NSString).length
            let currentLocation = selectedRange().location
            let clearRange = NSRange(location: max(currentLocation - lineLength, 0), length: min(lineLength, currentLocation))
            if clearRange.location >= 0 {
                insertText("", replacementRange: clearRange)
            }
            return nil
        }

        if marker.range(of: #"^\d+[.]$"#, options: .regularExpression) != nil {
            let number = Int(marker.dropLast()) ?? 1
            return "\(indent)\(number + 1). "
        }

        return "\(indent)\(marker) \(checkbox)"
    }
    private var protectedVisibleOrigin: NSPoint?
    private var protectionDepth = 0

    override func mouseDown(with event: NSEvent) {
        beginViewportProtection()
        super.mouseDown(with: event)
        restoreProtectedVisibleOrigin(clearProtection: false)
        DispatchQueue.main.async { [weak self] in
            self?.restoreProtectedVisibleOrigin(clearProtection: true)
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard protectedVisibleOrigin == nil else { return }
        super.scrollRangeToVisible(range)
    }

    func preserveViewportDuring(_ updates: () -> Void) {
        beginViewportProtection()
        updates()
        restoreProtectedVisibleOrigin(clearProtection: false)
        DispatchQueue.main.async { [weak self] in
            self?.restoreProtectedVisibleOrigin(clearProtection: true)
        }
    }

    private func beginViewportProtection() {
        protectionDepth += 1
        if protectedVisibleOrigin == nil {
            protectedVisibleOrigin = enclosingScrollView?.contentView.bounds.origin
        }
    }

    private func restoreProtectedVisibleOrigin(clearProtection: Bool) {
        guard let origin = protectedVisibleOrigin, let scrollView = enclosingScrollView else { return }
        if let textContainer {
            layoutManager?.ensureLayout(for: textContainer)
        }
        let clipView = scrollView.contentView
        let maxY = max(bounds.height - clipView.bounds.height, 0)
        let restoredOrigin = NSPoint(
            x: origin.x,
            y: min(max(origin.y, 0), maxY)
        )
        clipView.setBoundsOrigin(restoredOrigin)
        scrollView.reflectScrolledClipView(clipView)
        if clearProtection {
            protectionDepth = max(protectionDepth - 1, 0)
            if protectionDepth == 0 {
                protectedVisibleOrigin = nil
            }
        }
    }

    private func tableLineRecords(in text: NSString, fullRange: NSRange) -> [RenderedTableRow] {
        var records: [RenderedTableRow] = []
        text.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            records.append(RenderedTableRow(line: text.substring(with: range), range: range))
        }
        return records
    }

    private func renderedTableBlocks(in lines: [RenderedTableRow]) -> [RenderedTableBlock] {
        var blocks: [RenderedTableBlock] = []
        var index = 0

        while index + 1 < lines.count {
            guard isRenderedTableRow(lines[index].line),
                  isRenderedTableSeparator(lines[index + 1].line),
                  renderedTableCells(lines[index].line).count == renderedTableCells(lines[index + 1].line).count else {
                index += 1
                continue
            }

            var rows = [lines[index], lines[index + 1]]
            index += 2
            while index < lines.count, isRenderedTableRow(lines[index].line) {
                rows.append(lines[index])
                index += 1
            }
            blocks.append(RenderedTableBlock(rows: rows))
        }

        return blocks
    }
}

private struct RenderedTableRow {
    let line: String
    let range: NSRange
}

private struct RenderedTableBlock {
    let rows: [RenderedTableRow]
}

private func isRenderedTableRow(_ line: String) -> Bool {
    guard tableIndentWidth(line) <= 3 else { return false }
    return renderedTableCells(line).count >= 2
}

private func isRenderedTableSeparator(_ line: String) -> Bool {
    let cells = renderedTableCells(line)
    guard cells.count >= 2 else { return false }
    return cells.allSatisfy { cell in
        cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
    }
}

private func renderedTableCells(_ line: String) -> [String] {
    var cells: [String] = []
    var cell = ""
    var escaped = false
    var inCodeSpan = false
    var codeTickLength = 0
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var index = trimmed.startIndex

    while index < trimmed.endIndex {
        let character = trimmed[index]
        if escaped {
            cell.append(character)
            escaped = false
            index = trimmed.index(after: index)
            continue
        }

        if character == "\\" {
            cell.append(character)
            escaped = true
            index = trimmed.index(after: index)
            continue
        }

        if character == "`" {
            let runStart = index
            while index < trimmed.endIndex, trimmed[index] == "`" {
                index = trimmed.index(after: index)
            }
            let tickLength = trimmed.distance(from: runStart, to: index)
            if inCodeSpan, tickLength == codeTickLength {
                inCodeSpan = false
                codeTickLength = 0
            } else if !inCodeSpan {
                inCodeSpan = true
                codeTickLength = tickLength
            }
            cell.append(contentsOf: trimmed[runStart..<index])
            continue
        }

        if character == "|", !inCodeSpan {
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            cell = ""
            index = trimmed.index(after: index)
            continue
        }

        cell.append(character)
        index = trimmed.index(after: index)
    }

    cells.append(cell.trimmingCharacters(in: .whitespaces))

    if cells.first == "" {
        cells.removeFirst()
    }
    if cells.last == "" {
        cells.removeLast()
    }

    return cells
}

private func pipeOffsets(in line: String) -> [Int] {
    var offsets: [Int] = []
    var escaped = false
    var inCodeSpan = false
    var codeTickLength = 0
    var index = line.startIndex

    while index < line.endIndex {
        let character = line[index]

        if escaped {
            escaped = false
            index = line.index(after: index)
            continue
        }

        if character == "\\" {
            escaped = true
            index = line.index(after: index)
            continue
        }

        if character == "`" {
            let runStart = index
            while index < line.endIndex, line[index] == "`" {
                index = line.index(after: index)
            }
            let tickLength = line.distance(from: runStart, to: index)
            if inCodeSpan, tickLength == codeTickLength {
                inCodeSpan = false
                codeTickLength = 0
            } else if !inCodeSpan {
                inCodeSpan = true
                codeTickLength = tickLength
            }
            continue
        }

        if character == "|", !inCodeSpan {
            offsets.append(line.utf16.distance(from: line.utf16.startIndex, to: index.samePosition(in: line.utf16)!))
        }

        index = line.index(after: index)
    }

    return offsets
}

private func tableIndentWidth(_ line: String) -> Int {
    var width = 0
    for character in line {
        if character == " " {
            width += 1
        } else if character == "\t" {
            width += 4 - width % 4
        } else {
            break
        }
    }
    return width
}

final class MarkdownHighlighter {
    private let baseFont = NSFont.systemFont(ofSize: 17)
    private let monoFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    private let syntaxColor = NSColor.secondaryLabelColor

    private enum TableLineRole {
        case header
        case separator
        case body
    }

    static func heading(in line: String) -> (level: Int, title: String)? {
        guard let match = line.range(of: #"^(#{1,6})\s+(.+)$"#, options: .regularExpression) else { return nil }
        let value = String(line[match])
        let level = value.prefix { $0 == "#" }.count
        let title = value.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (level, title)
    }

    static func slugify(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        var previousWasSeparator = false

        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value >= 0x4E00 && scalar.value <= 0x9FFF || scalar == UnicodeScalar("_") || scalar == UnicodeScalar("-") {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar), !previousWasSeparator, !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func apply(to storage: NSTextStorage, activeLine: NSRange?, changedRange: NSRange? = nil) {
        let full = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        let renderRange = changedRange.map { expandedRenderRange(for: $0, in: text, fullRange: full) } ?? full

        guard renderRange.location != NSNotFound, renderRange.length >= 0, renderRange.upperBound <= storage.length else { return }

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.textBackgroundColor,
            .paragraphStyle: paragraphStyle()
        ], range: renderRange)

        let lines = lineRecords(in: text, fullRange: renderRange)
        let tableRoles = tableLineRoles(in: lines)
        let tableRanges = mergedRanges(for: tableRoles.keys.map { lines[$0].range })
        var inCodeBlock = isInCodeBlock(at: renderRange.location, text: text)
        var codeBlockRanges: [NSRange] = []
        var codeBlockStart: Int?

        if inCodeBlock {
            codeBlockStart = renderRange.location
        }

        for (index, record) in lines.enumerated() {
            guard record.range.length > 0 else { continue }
            self.styleLine(
                record.line,
                range: record.range,
                storage: storage,
                inCodeBlock: inCodeBlock,
                tableRole: inCodeBlock ? nil : tableRoles[index],
                isActive: self.intersects(record.range, activeLine)
            )
            if self.isCodeFence(record.line) {
                if let start = codeBlockStart {
                    codeBlockRanges.append(clampedRange(NSRange(location: start, length: record.range.upperBound - start), to: renderRange))
                    codeBlockStart = nil
                } else {
                    codeBlockStart = record.range.location
                }
                inCodeBlock.toggle()
            }
        }
        if let start = codeBlockStart {
            codeBlockRanges.append(clampedRange(NSRange(location: start, length: renderRange.upperBound - start), to: renderRange))
        }

        styleInlineMarkdown(storage, activeLine: activeLine, excludedRanges: codeBlockRanges + tableRanges, searchRange: renderRange)
        storage.endEditing()
    }

    private func styleLine(_ line: String, range: NSRange, storage: NSTextStorage, inCodeBlock: Bool, tableRole: TableLineRole?, isActive: Bool) {
        if inCodeBlock || isCodeFence(line) {
            let fence = isCodeFence(line)
            storage.addAttributes([
                .font: monoFont,
                .foregroundColor: fence ? (isActive ? syntaxColor : NSColor.tertiaryLabelColor) : NSColor.labelColor,
                .backgroundColor: NSColor.controlBackgroundColor,
                .paragraphStyle: paragraphStyle(firstLineHeadIndent: 18, headIndent: 18, paragraphSpacing: 4)
            ], range: range)
            if fence, !isActive {
                hideSyntax(in: range, storage: storage)
            }
            return
        }

        if let tableRole {
            styleTableLine(line, range: range, storage: storage, role: tableRole)
            return
        }

        if let heading = Self.heading(in: line) {
            let fontSize: CGFloat
            switch heading.level {
            case 1: fontSize = 34
            case 2: fontSize = 27
            case 3: fontSize = 22
            default: fontSize = 18
            }
            let markerLength = min(heading.level + 1, range.length)
            let markerRange = NSRange(location: range.location, length: markerLength)
            let titleRange = NSRange(location: range.location + markerLength, length: max(range.length - markerLength, 0))
            storage.addAttributes([
                .font: NSFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle(paragraphSpacing: heading.level <= 2 ? 18 : 12)
            ], range: range)
            if isActive {
                storage.addAttributes([
                    .font: NSFont.boldSystemFont(ofSize: max(fontSize - 6, 13)),
                    .foregroundColor: syntaxColor
                ], range: markerRange)
            } else {
                hideSyntax(in: markerRange, storage: storage)
            }
            storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: fontSize)], range: titleRange)
        } else if line.hasPrefix("> ") {
            let style = paragraphStyle(firstLineHeadIndent: 18, headIndent: 18)
            storage.addAttributes([
                .paragraphStyle: style,
                .foregroundColor: syntaxColor
            ], range: range)
            let markerRange = NSRange(location: range.location, length: min(2, range.length))
            if isActive {
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: markerRange)
            } else {
                hideSyntax(in: markerRange, storage: storage)
            }
        } else if line.trimmingCharacters(in: .whitespaces) == "---" {
            storage.addAttributes([
                .foregroundColor: NSColor.separatorColor,
                .paragraphStyle: paragraphStyle(paragraphSpacing: 18)
            ], range: range)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
            storage.addAttributes([.paragraphStyle: paragraphStyle(firstLineHeadIndent: 0, headIndent: 22)], range: range)
            let markerLength = listMarkerLength(line)
            let markerRange = NSRange(location: range.location, length: min(markerLength, range.length))
            if isActive {
                storage.addAttributes([.foregroundColor: syntaxColor], range: markerRange)
            } else {
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor], range: markerRange)
            }
        }
    }

    private func styleTableLine(_ line: String, range: NSRange, storage: NSTextStorage, role: TableLineRole) {
        let foreground: NSColor
        let background: NSColor
        let font: NSFont

        switch role {
        case .header:
            foreground = NSColor.labelColor
            background = NSColor.controlBackgroundColor
            font = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        case .separator:
            foreground = NSColor.tertiaryLabelColor
            background = NSColor.controlBackgroundColor
            font = monoFont
        case .body:
            foreground = NSColor.labelColor
            background = NSColor.textBackgroundColor
            font = monoFont
        }

        storage.addAttributes([
            .font: font,
            .foregroundColor: foreground,
            .backgroundColor: background,
            .paragraphStyle: paragraphStyle(firstLineHeadIndent: 18, headIndent: 18, paragraphSpacing: 2)
        ], range: range)

        if role == .separator {
            return
        }

        for pipeRange in pipeRanges(in: line, lineRange: range) {
            storage.addAttributes([.foregroundColor: syntaxColor], range: pipeRange)
        }
    }

    private func styleInlineMarkdown(_ storage: NSTextStorage, activeLine: NSRange?, excludedRanges: [NSRange], searchRange: NSRange) {
        applyRegex(#"`([^`]+)`"#, storage: storage, range: searchRange) { match in
            guard !self.intersectsAny(match.range, excludedRanges) else { return }
            let isActive = self.intersects(match.range, activeLine)
            if isActive {
                storage.addAttributes([.foregroundColor: self.syntaxColor], range: match.range)
            } else {
                self.hideSyntax(in: NSRange(location: match.range.location, length: 1), storage: storage)
                self.hideSyntax(in: NSRange(location: match.range.upperBound - 1, length: 1), storage: storage)
            }
            storage.addAttributes([
                .font: self.monoFont,
                .foregroundColor: NSColor.controlAccentColor,
                .backgroundColor: NSColor.controlBackgroundColor
            ], range: match.range(at: 1))
        }

        applyRegex(#"\*\*([^*]+)\*\*"#, storage: storage, range: searchRange) { match in
            guard !self.intersectsAny(match.range, excludedRanges) else { return }
            let isActive = self.intersects(match.range, activeLine)
            if isActive {
                storage.addAttributes([.foregroundColor: self.syntaxColor], range: match.range)
            } else {
                self.hideSyntax(in: NSRange(location: match.range.location, length: 2), storage: storage)
                self.hideSyntax(in: NSRange(location: match.range.upperBound - 2, length: 2), storage: storage)
            }
            storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.labelColor], range: match.range(at: 1))
        }

        applyRegex(#"(?<!\*)\*([^*]+)\*(?!\*)"#, storage: storage, range: searchRange) { match in
            guard !self.intersectsAny(match.range, excludedRanges) else { return }
            let italic = NSFontManager.shared.convert(self.baseFont, toHaveTrait: .italicFontMask)
            let isActive = self.intersects(match.range, activeLine)
            if isActive {
                storage.addAttributes([.foregroundColor: self.syntaxColor], range: match.range)
            } else {
                self.hideSyntax(in: NSRange(location: match.range.location, length: 1), storage: storage)
                self.hideSyntax(in: NSRange(location: match.range.upperBound - 1, length: 1), storage: storage)
            }
            storage.addAttributes([.font: italic, .foregroundColor: NSColor.labelColor], range: match.range(at: 1))
        }

        applyRegex(#"\[([^\]]+)\]\(([^)]+)\)"#, storage: storage, range: searchRange) { match in
            guard !self.intersectsAny(match.range, excludedRanges) else { return }
            let isActive = self.intersects(match.range, activeLine)
            if isActive {
                storage.addAttributes([.foregroundColor: self.syntaxColor], range: match.range)
            } else {
                self.hideSyntax(in: NSRange(location: match.range.location, length: 1), storage: storage)
                let closeLabel = NSRange(location: match.range(at: 1).upperBound, length: 2)
                let closeLink = NSRange(location: match.range.upperBound - 1, length: 1)
                self.hideSyntax(in: closeLabel, storage: storage)
                self.hideSyntax(in: match.range(at: 2), storage: storage)
                self.hideSyntax(in: closeLink, storage: storage)
            }
            storage.addAttributes([
                .foregroundColor: NSColor.controlAccentColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range(at: 1))
        }
    }

    private func expandedRenderRange(for changedRange: NSRange, in text: NSString, fullRange: NSRange) -> NSRange {
        guard fullRange.length > 0 else { return fullRange }
        let location = min(max(changedRange.location, 0), fullRange.length)
        let length = min(max(changedRange.length, 0), max(fullRange.length - location, 0))
        var range = text.lineRange(for: NSRange(location: location, length: length))

        if range.location > 0 {
            let previousLocation = max(range.location - 1, 0)
            range = NSUnionRange(range, text.lineRange(for: NSRange(location: previousLocation, length: 0)))
        }

        if range.upperBound < fullRange.upperBound {
            range = NSUnionRange(range, text.lineRange(for: NSRange(location: range.upperBound, length: 0)))
        }

        range = includeNeighborLines(around: range, in: text, fullRange: fullRange, count: 2)

        while range.location > 0 {
            let previousLine = text.lineRange(for: NSRange(location: max(range.location - 1, 0), length: 0))
            let previousText = text.substring(with: previousLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !previousText.isEmpty, shouldExtendBlock(previousText) else { break }
            range = NSUnionRange(range, previousLine)
        }

        while range.upperBound < fullRange.upperBound {
            let nextLine = text.lineRange(for: NSRange(location: range.upperBound, length: 0))
            let nextText = text.substring(with: nextLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nextText.isEmpty, shouldExtendBlock(nextText) else { break }
            range = NSUnionRange(range, nextLine)
        }

        return clampedRange(range, to: fullRange)
    }

    private func includeNeighborLines(around range: NSRange, in text: NSString, fullRange: NSRange, count: Int) -> NSRange {
        var expanded = range

        for _ in 0..<count {
            guard expanded.location > fullRange.location else { break }
            let previousLine = text.lineRange(for: NSRange(location: max(expanded.location - 1, fullRange.location), length: 0))
            expanded = NSUnionRange(expanded, previousLine)
        }

        for _ in 0..<count {
            guard expanded.upperBound < fullRange.upperBound else { break }
            let nextLine = text.lineRange(for: NSRange(location: expanded.upperBound, length: 0))
            expanded = NSUnionRange(expanded, nextLine)
        }

        return clampedRange(expanded, to: fullRange)
    }

    private func shouldExtendBlock(_ line: String) -> Bool {
        isRenderedTableRow(line)
            || isRenderedTableSeparator(line)
            || line.range(of: #"^(\s*)(([-*+]|\d+[.])\s+)"#, options: .regularExpression) != nil
            || isCodeFence(line)
    }

    private func isInCodeBlock(at location: Int, text: NSString) -> Bool {
        guard location > 0 else { return false }
        var inCodeBlock = false
        let prefixRange = NSRange(location: 0, length: min(location, text.length))
        text.enumerateSubstrings(in: prefixRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            if self.isCodeFence(text.substring(with: range)) {
                inCodeBlock.toggle()
            }
        }
        return inCodeBlock
    }

    private func clampedRange(_ range: NSRange, to bounds: NSRange) -> NSRange {
        let lower = max(range.location, bounds.location)
        let upper = min(range.upperBound, bounds.upperBound)
        return NSRange(location: lower, length: max(upper - lower, 0))
    }

    private func lineRecords(in text: NSString, fullRange: NSRange) -> [(line: String, range: NSRange)] {
        var records: [(line: String, range: NSRange)] = []
        text.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            records.append((text.substring(with: range), range))
        }
        return records
    }

    private func tableLineRoles(in lines: [(line: String, range: NSRange)]) -> [Int: TableLineRole] {
        var roles: [Int: TableLineRole] = [:]
        var index = 0

        while index + 1 < lines.count {
            guard isPotentialTableRow(lines[index].line),
                  isTableSeparator(lines[index + 1].line),
                  markdownTableCells(lines[index].line).count == markdownTableCells(lines[index + 1].line).count else {
                index += 1
                continue
            }

            roles[index] = .header
            roles[index + 1] = .separator
            index += 2

            while index < lines.count, isPotentialTableRow(lines[index].line) {
                roles[index] = .body
                index += 1
            }
        }

        return roles
    }

    private func isPotentialTableRow(_ line: String) -> Bool {
        isRenderedTableRow(line)
    }

    private func isTableSeparator(_ line: String) -> Bool {
        isRenderedTableSeparator(line)
    }

    private func markdownTableCells(_ line: String) -> [String] {
        renderedTableCells(line)
    }

    private func mergedRanges(for ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []

        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if range.location <= last.upperBound {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(last.upperBound, range.upperBound) - last.location)
            } else {
                merged.append(range)
            }
        }

        return merged
    }

    private func pipeRanges(in line: String, lineRange: NSRange) -> [NSRange] {
        pipeOffsets(in: line).map { NSRange(location: lineRange.location + $0, length: 1) }
    }

    private func applyRegex(_ pattern: String, storage: NSTextStorage, range: NSRange, action: (NSTextCheckingResult) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let match else { return }
            action(match)
        }
    }

    private func hideSyntax(in range: NSRange, storage: NSTextStorage) {
        guard range.location >= 0, range.length > 0, range.upperBound <= storage.length else { return }
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: 1),
            .foregroundColor: NSColor.textBackgroundColor,
            .backgroundColor: NSColor.textBackgroundColor
        ], range: range)
    }

    private func intersects(_ range: NSRange, _ other: NSRange?) -> Bool {
        guard let other else { return false }
        return NSIntersectionRange(range, other).length > 0
    }

    private func intersectsAny(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private func isCodeFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private func listMarkerLength(_ line: String) -> Int {
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return 6 }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return 2 }
        guard let match = line.range(of: #"^\d+\. "#, options: .regularExpression) else { return 0 }
        return line.distance(from: line.startIndex, to: match.upperBound)
    }

    private func paragraphStyle(firstLineHeadIndent: CGFloat = 0, headIndent: CGFloat = 0, paragraphSpacing: CGFloat = 9) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = paragraphSpacing
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        return style
    }
}

@main
struct MarkLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MarkLens", id: "main") {
            MarkLensAppView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open File") {
                    NotificationCenter.default.post(name: .markLensOpenFileCommand, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("New Note") {
                    NotificationCenter.default.post(name: .markLensNewNoteCommand, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(after: .textEditing) {
                Button("Indent") {
                    NotificationCenter.default.post(name: .markLensFormatCommand, object: EditorCommand.indent)
                }
                .keyboardShortcut("]", modifiers: [.command])

                Button("Outdent") {
                    NotificationCenter.default.post(name: .markLensFormatCommand, object: EditorCommand.outdent)
                }
                .keyboardShortcut("[", modifiers: [.command])
            }
        }
    }
}
