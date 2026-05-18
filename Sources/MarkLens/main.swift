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

    init() {
        loadSampleWorkspace()
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
        tree = scan(url)
        if let first = firstFile(in: tree) {
            select(first)
        } else {
            selectedFile = nil
            text = "# Empty Workspace\n\nNo Markdown files were found in this folder.\n"
            status = "No Markdown files"
        }
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

    private func loadSampleWorkspace() {
        let sample = MarkdownFile(
            id: URL(fileURLWithPath: "/Samples/welcome.md"),
            url: URL(fileURLWithPath: "/Samples/welcome.md")
        )
        selectedFile = sample
        text = """
        # Welcome to MarkLens

        MarkLens is a native macOS Markdown editor. It keeps writing and preview in one surface, so the document stays readable while you edit.

        ## Native by design

        - SwiftUI window and sidebar
        - AppKit TextKit editor for fast text handling
        - Debounced local file saves
        - No local web server

        > Open a folder, select a Markdown file, and keep writing.

        ```swift
        let app = "MarkLens"
        print("\\(app) renders as you type")
        ```
        """
        wordCount = Self.countWords(text)
        tree = [
            FileNode(
                id: URL(fileURLWithPath: "/Samples"),
                url: URL(fileURLWithPath: "/Samples"),
                name: "Samples",
                file: nil,
                children: [FileNode(id: sample.id, url: sample.url, name: sample.name, file: sample, children: nil)]
            )
        ]
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
}

struct MarkLensAppView: View {
    @StateObject private var model = WorkspaceModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            VStack(spacing: 0) {
                topbar
                MarkdownTextView(text: $model.text, onChange: model.textChanged)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .onReceive(NotificationCenter.default.publisher(for: .markLensNewNoteCommand)) { _ in
            model.newNote()
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.openFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
                Button(action: model.newNote) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                Button(action: model.refreshTree) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ToolbarItemGroup {
                formatButton("H1", command: .heading1)
                formatButton("H2", command: .heading2)
                formatButton("B", command: .bold)
                formatButton("I", command: .italic)
                formatButton("Code", command: .code)
                formatButton("Quote", command: .quote)
                formatButton("List", command: .list)
                formatButton("Task", command: .task)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .cornerRadius(8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MarkLens").font(.headline)
                    Text(model.rootURL?.lastPathComponent ?? "Native Markdown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            List(selection: Binding(get: { model.selectedFile?.id }, set: { _ in })) {
                OutlineGroup(model.tree, children: \.children) { node in
                    if let file = node.file {
                        Button {
                            model.select(file)
                        } label: {
                            Label(file.name, systemImage: "doc.text")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.selectedFile?.id == file.id ? .primary : .secondary)
                    } else {
                        Label(node.name, systemImage: "folder")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private var topbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedFile?.url.deletingLastPathComponent().path(percentEncoded: false) ?? "Sample workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.selectedFile?.name ?? "Untitled")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            Text(model.status)
                .foregroundStyle(.secondary)
            Text("\(model.wordCount) words")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func formatButton(_ title: String, command: EditorCommand) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .markLensFormatCommand, object: command)
        }
    }
}

enum EditorCommand {
    case heading1, heading2, bold, italic, code, quote, list, task
}

extension Notification.Name {
    static let markLensFormatCommand = Notification.Name("MarkLensFormatCommand")
    static let markLensNewNoteCommand = Notification.Name("MarkLensNewNoteCommand")
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.textBackgroundColor

        let textView = NSTextView()
        textView.isRichText = false
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
        textView.textContainerInset = NSSize(width: 72, height: 54)
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
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        private var observer: NSObjectProtocol?
        private var highlightTask: Task<Void, Never>?
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
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.onChange(textView.string)
            scheduleHighlighting()
        }

        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRanges
            highlighter.apply(to: storage)
            textView.selectedRanges = selection
        }

        private func scheduleHighlighting() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                self?.applyHighlighting()
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
            case .bold:
                wrapSelection("**", in: textView)
            case .italic:
                wrapSelection("*", in: textView)
            case .code:
                wrapSelection("`", in: textView)
            }
            parent.onChange(textView.string)
            applyHighlighting()
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
    }
}

final class MarkdownHighlighter {
    private let baseFont = NSFont.systemFont(ofSize: 17)
    private let monoFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.textBackgroundColor,
            .paragraphStyle: paragraphStyle()
        ], range: full)

        let text = storage.string as NSString
        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let line = text.substring(with: range)
            self.styleLine(line, range: range, storage: storage)
        }

        styleInline(pattern: "`([^`]+)`", storage: storage, attributes: [
            .font: monoFont,
            .foregroundColor: NSColor.controlAccentColor,
            .backgroundColor: NSColor.controlBackgroundColor
        ])
        styleInline(pattern: "\\*\\*([^*]+)\\*\\*", storage: storage, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 17)
        ])
        storage.endEditing()
    }

    private func styleLine(_ line: String, range: NSRange, storage: NSTextStorage) {
        if line.hasPrefix("# ") {
            storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: 34)], range: range)
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: range.location, length: 1))
        } else if line.hasPrefix("## ") {
            storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: 26)], range: range)
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: range.location, length: 2))
        } else if line.hasPrefix("### ") {
            storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: 21)], range: range)
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor], range: NSRange(location: range.location, length: 3))
        } else if line.hasPrefix("> ") {
            let style = paragraphStyle(firstLineHeadIndent: 18, headIndent: 18)
            storage.addAttributes([
                .paragraphStyle: style,
                .foregroundColor: NSColor.secondaryLabelColor
            ], range: range)
        } else if line.hasPrefix("```") {
            storage.addAttributes([
                .font: monoFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ], range: range)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
            storage.addAttributes([.paragraphStyle: paragraphStyle(firstLineHeadIndent: 0, headIndent: 22)], range: range)
        }
    }

    private func styleInline(pattern: String, storage: NSTextStorage, attributes: [NSAttributedString.Key: Any]) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let full = NSRange(location: 0, length: storage.length)
        regex.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            guard let match else { return }
            storage.addAttributes(attributes, range: match.range)
        }
    }

    private func paragraphStyle(firstLineHeadIndent: CGFloat = 0, headIndent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 9
        style.firstLineHeadIndent = firstLineHeadIndent
        style.headIndent = headIndent
        return style
    }
}

@main
struct MarkLensApp: App {
    var body: some Scene {
        WindowGroup {
            MarkLensAppView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    NotificationCenter.default.post(name: .markLensNewNoteCommand, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
