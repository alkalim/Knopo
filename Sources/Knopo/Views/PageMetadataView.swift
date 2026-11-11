import SwiftUI
import KnopoCore

/// Page properties share the outline's rendered and source-editing presentation.
struct PageMetadataView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let pageName: String
    @ObservedObject var session: PagePropertyEditSession
    let addRequest: UUID?
    var onRequestHandled: () -> Void = {}
    @State private var hovered: Int?
    @FocusState private var focusedProperty: Int?

    var body: some View {
        let _ = app.dataVersion
        let document = app.document(for: pageName)
        let rows = Self.rows(in: document)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .property(let index, let property):
                    if session.inserting, session.index == index { editor }
                    propertyRow(property, index: index, source: document.preamble)
                case .text(let source):
                    PagePreambleText(source: source)
                }
            }
            if let index = session.index, index >= document.preambleProperties.count {
                editor
            }
        }
        .padding(.leading, OutlineRowCell.gutterWidth)
        .onChange(of: addRequest) { _, request in
            if request != nil {
                begin(at: app.document(for: pageName).preambleProperties.count)
                onRequestHandled()
            }
        }
        .onAppear {
            if addRequest != nil {
                begin(at: document.preambleProperties.count)
                onRequestHandled()
            } else {
                session.restore(app: app, pageName: pageName)
            }
        }
        .onChange(of: pageName) { _, name in
            session.leave()
            session.restore(app: app, pageName: name)
        }
        .onDisappear { session.leave() }
    }

    @ViewBuilder private func propertyRow(_ property: BlockProperty, index: Int, source: String) -> some View {
        if !session.inserting, session.index == index {
            editor
        } else {
            HStack(alignment: .center, spacing: 4) {
                ResultBlockText(text: Self.render(property),
                                onLink: { nav.openURL($0, inSidebar: $1) },
                                fitsContent: true, verticalInset: 1,
                                onClick: { _, _ in begin(at: index, source: source) })
                Button { begin(at: index, source: source) } label: {
                    Image(systemName: "pencil").font(.caption)
                        .opacity(hovered == index || focusedProperty == index ? 0.65 : 0)
                }
                .buttonStyle(.plain)
                .focused($focusedProperty, equals: index)
                .accessibilityLabel("Edit Property")
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? index : nil }
            .contextMenu {
                Button("Edit Property") { begin(at: index, source: source) }
                Button("Remove Property") {
                    guard session.finish() else { return }
                    var document = app.document(for: pageName)
                    guard let target = session.resolve(index: index, source: source, current: document.preamble) else { return }
                    let before = document.preamble
                    guard document.setPreambleProperty(at: target, to: nil) else { return }
                    app.commitPagePreamble(document.preamble, for: pageName, expected: before)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 2) {
            PagePropertyEditor(session: session, font: BlockEditorTextView.editorFont, fetchTags: { prefix in
                (try? app.store.cache.tags(withPrefix: prefix)) ?? []
            })
            .id(session.revision)
            if let error = session.error {
                Text(verbatim: error).font(.caption).foregroundStyle(.secondary)
                if session.conflicted {
                    Button("Reload Property") { session.reload() }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func begin(at index: Int) {
        session.begin(app: app, pageName: pageName, index: index)
    }

    private func begin(at index: Int, source: String) {
        guard session.finish(),
              let target = session.resolve(index: index, source: source,
                                           current: app.document(for: pageName).preamble) else { return }
        begin(at: target)
    }

    enum Row {
        case property(Int, BlockProperty)
        case text(String)
    }

    static func rows(in document: PageDocument) -> [Row] {
        var rows: [Row] = []
        var text: [String] = []
        var index = 0
        func flush() {
            let source = text.joined(separator: "\n")
            if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rows.append(.text(source)) }
            text.removeAll(keepingCapacity: true)
        }
        for line in document.preambleLines {
            if let property = line.property {
                flush()
                rows.append(.property(index, property))
                index += 1
            } else { text.append(line.text) }
        }
        flush()
        return rows
    }

    static func render(_ property: BlockProperty) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\(property.key): ", attributes: [
            .font: BlockEditorTextView.editorFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        if property.key.lowercased() == "tags" {
            let tags = PageTagValue.tokens(in: property.value)
            let source = tags.map { "#[[\($0.name)]]" }.joined(separator: " ")
            result.append(BlockRenderer.render(content: source, context: .init()))
        } else {
            result.append(NSAttributedString(string: property.value, attributes: [
                .font: BlockEditorTextView.editorFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }
}

private struct PagePreambleText: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let source: String

    var body: some View {
        ResultBlockText(text: BlockRenderer.render(content: source, context: .init(
            resolveBlockRef: { app.store.resolveBlock($0)?.block.content }, assetsDir: app.store.assetsDir)),
                        onLink: { nav.openURL($0, inSidebar: $1) }, allowsTextSelection: true)
    }
}

struct PagePropertyDraft {
    let index: Int
    let text: String
    let expected: String
    let inserting: Bool
    let error: String?
    let conflicted: Bool
}

@MainActor
final class PagePropertyEditSession: ObservableObject {
    @Published var index: Int?
    @Published private(set) var inserting = false
    @Published private(set) var revision = UUID()
    weak var outline: OutlineEditorController?
    var selection: NSRange?
    @Published var text = ""
    @Published var error: String?
    @Published var conflicted = false
    private weak var app: AppState?
    private var pageName = ""
    private var expected = ""
    private var finishing = false
    private(set) var requestsFocus = true
    private var lastChange: (before: String, after: String, index: Int, count: Int)?

    func resolve(index: Int, source: String, current: String) -> Int? {
        if source == current { return index }
        guard let change = lastChange, change.before == source, change.after == current else { return nil }
        return Self.targetIndex(index, afterEditing: change.index, countChange: change.count)
    }

    func begin(app: AppState, pageName: String, index requestedIndex: Int, inserting: Bool = false) {
        let oldIndex = self.pageName == pageName ? self.index : nil
        let count = app.document(for: pageName).preambleProperties.count
        guard finish() else { return }
        let index = Self.targetIndex(requestedIndex, afterEditing: oldIndex,
            countChange: app.document(for: pageName).preambleProperties.count - count)
        guard app.activeMetadataSession?.finish() != false else { return }
        app.closePendingEdit?()
        self.app = app
        self.pageName = pageName
        let document = app.document(for: pageName)
        expected = document.preamble
        self.index = index
        self.inserting = inserting
        requestsFocus = true
        revision = UUID()
        selection = nil
        let properties = document.preambleProperties
        text = !inserting && properties.indices.contains(index) ? "\(properties[index].key):: \(properties[index].value)" : ""
        error = nil
        conflicted = false
        app.activeMetadataSession = self
    }

    func canApplyUndo(_ documents: [PageDocument]) -> Bool {
        guard let app, index != nil else { return true }
        return !documents.contains {
            PageName.key($0.name) == PageName.key(pageName)
                && $0.preamble != app.document(for: pageName).preamble
        }
    }

    func activate() -> Bool {
        guard let app else { return true }
        requestsFocus = true
        if app.activeMetadataSession === self { return true }
        guard app.activeMetadataSession?.finish() != false else { return false }
        app.closePendingEdit?()
        app.activeMetadataSession = self
        return true
    }

    static func targetIndex(_ requested: Int, afterEditing index: Int?, countChange: Int) -> Int {
        guard let index else { return requested }
        if countChange > 0, index <= requested { return requested + countChange }
        if countChange < 0, index < requested { return requested + countChange }
        return requested
    }

    @discardableResult func finish() -> Bool { save(endingEdit: true) }

    /// Background saves keep the caret and unfinished rows in place.
    func saveDraft() { _ = save(endingEdit: false) }

    private func save(endingEdit: Bool) -> Bool {
        guard !finishing, let index, let app else { return self.index == nil }
        finishing = true
        defer { finishing = false }
        var document = app.document(for: pageName)
        let originalCount = document.preambleProperties.count
        guard document.preamble == expected else {
            if endingEdit {
                conflicted = true
                error = String(localized: "This property changed elsewhere. Reload it before editing.", comment: "Inline page property edit conflict")
            }
            return false
        }
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard endingEdit || !empty else { return false }
        let property = PageParser.matchProperty(text)
        guard !text.contains(where: { $0.isNewline }),
              empty || property.map(PageDocument.isValidPreambleProperty) == true else {
            if endingEdit {
                error = String(localized: "Use name:: value on one line.", comment: "Invalid inline page property source")
            }
            return false
        }
        if inserting {
            if let property, !empty {
                guard document.insertPreambleProperty(property, at: index) else { return false }
            }
        } else if !empty || index < document.preambleProperties.count {
            guard document.setPreambleProperty(at: index, to: empty ? nil : property) else { return false }
        }
        if !endingEdit, document.preamble == expected { return true }
        guard app.commitPagePreamble(document.preamble, for: pageName, expected: expected) else { return false }
        if document.preamble != expected {
            lastChange = (expected, document.preamble, index, document.preambleProperties.count - originalCount)
        }
        expected = document.preamble
        if endingEdit {
            self.index = nil
            error = nil
            if app.activeMetadataSession === self { app.activeMetadataSession = nil }
        } else if inserting || index == originalCount {
            inserting = false
            // The saved row replaces the draft's temporary position in the view.
            revision = UUID()
        }
        return true
    }

    func move(by delta: Int) {
        guard let app, let index else { return }
        let count = app.document(for: pageName).preambleProperties.count
        let blankInsertion = inserting && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard finish() else { return }
        let removed = count - app.document(for: pageName).preambleProperties.count
        let next = delta > 0 && blankInsertion ? index : index + delta - (delta > 0 ? max(0, removed) : 0)
        if app.document(for: pageName).preambleProperties.indices.contains(next) {
            begin(app: app, pageName: pageName, index: next)
        }
    }

    /// Enter continues metadata; a blank line returns to the outline.
    func enter() {
        guard let app, let index else { return }
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard finish() else { return }
        if empty {
            if outline?.pageName == pageName { outline?.focusAfterPageProperties() }
        } else {
            begin(app: app, pageName: pageName, index: index + 1, inserting: true)
        }
    }

    func leave() {
        guard let app, let index else { return }
        if !finish() {
            app.metadataDrafts[PageName.key(pageName)] = PagePropertyDraft(index: index, text: text,
                expected: expected, inserting: inserting, error: error, conflicted: conflicted)
            if app.activeMetadataSession === self { app.activeMetadataSession = nil }
            self.index = nil
        }
    }

    func restore(app: AppState, pageName: String) {
        guard let draft = app.metadataDrafts[PageName.key(pageName)] else { return }
        self.app = app
        self.pageName = pageName
        index = draft.index
        inserting = draft.inserting
        revision = UUID()
        requestsFocus = false
        selection = nil
        app.metadataDrafts.removeValue(forKey: PageName.key(pageName))
        text = draft.text
        expected = draft.expected
        error = draft.error
        conflicted = draft.conflicted
    }

    func reload() {
        guard let app, let index else { return }
        let draft = text
        let current = app.document(for: pageName).preambleProperties
        let previous = PageDocument(name: pageName, preamble: expected).preambleProperties
        var target = min(index, current.count)
        var add = inserting || index >= previous.count
        if !add {
            let property = previous[index]
            let exact = current.indices.filter { current[$0] == property }
            let exactOrdinal = previous[..<index].filter { $0 == property }.count
            let matchingKey = current.indices.filter { current[$0].key == property.key }
            let keyOrdinal = previous[..<index].filter { $0.key == property.key }.count
            if exact.indices.contains(exactOrdinal) { target = exact[exactOrdinal] }
            else if matchingKey.indices.contains(keyOrdinal) { target = matchingKey[keyOrdinal] }
            else { add = true }
        }
        self.index = nil
        begin(app: app, pageName: pageName, index: target, inserting: add)
        if add { text = draft }
    }
}

private struct PagePropertyEditor: NSViewRepresentable {
    @ObservedObject var session: PagePropertyEditSession
    let font: NSFont
    var fetchTags: (String) -> [String]

    func makeNSView(context: Context) -> PagePropertyTextView {
        let view = PagePropertyTextView(usingTextLayoutManager: true)
        view.isRichText = false
        view.allowsUndo = false
        view.font = font
        view.textColor = BlockRenderer.bodyColor
        view.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06)
        view.insertionPointColor = .controlAccentColor
        view.textContainerInset = NSSize(width: 0, height: 1)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.autocomplete.pagePropertyEditing = true
        view.setAccessibilityLabel(L("Page Property"))
        view.string = session.text
        view.session = session
        view.revision = session.revision
        return view
    }

    func updateNSView(_ view: PagePropertyTextView, context: Context) {
        guard view.revision == session.revision else { return }
        view.session = session
        view.autocomplete.fetchTags = fetchTags
        if view.font != font { view.font = font }
        if view.string != session.text { view.string = session.text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PagePropertyTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        return CGSize(width: width, height: nsView.measuredHeight(forWidth: width))
    }

    static func dismantleNSView(_ view: PagePropertyTextView, coordinator: ()) {
        view.autocomplete.dismiss()
    }
}

final class PagePropertyTextView: NSTextView {
    let autocomplete = AutocompleteController()
    weak var session: PagePropertyEditSession?
    var revision: UUID?

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        let text = string.isEmpty ? NSAttributedString(string: " ", attributes: typingAttributes) : attributedString()
        let inset = textContainerInset
        return OutlineRowCell.textHeight(for: text, contentWidth: max(1, width - inset.width * 2))
            + inset.height * 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  self.session?.revision == self.revision, self.session?.index != nil,
                  self.session?.requestsFocus == true else { return }
            window.makeFirstResponder(self)
            let selection = self.session?.selection ?? NSRange(location: (self.string as NSString).length, length: 0)
            self.setSelectedRange(selection)
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard session?.activate() != false else { return false }
        return super.becomeFirstResponder()
    }

    override func didChangeText() {
        super.didChangeText()
        guard session?.revision == revision else { return }
        session?.text = string
        session?.selection = selectedRange()
        invalidateIntrinsicContentSize()
        autocomplete.textDidChange(in: self)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if session?.revision == revision { session?.selection = selectedRange() }
        if autocomplete.isActive { autocomplete.textDidChange(in: self) }
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        if autocomplete.handleKeyDown(event) { return }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            autocomplete.dismiss()
            if session?.revision == revision { session?.enter() }
        case #selector(NSResponder.cancelOperation(_:)):
            autocomplete.dismiss()
            if session?.revision == revision, session?.finish() == true { window?.makeFirstResponder(nil) }
        case #selector(NSResponder.insertTab(_:)): autocomplete.dismiss(); session?.move(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): autocomplete.dismiss(); session?.move(by: -1)
        default: super.doCommand(by: selector)
        }
    }

    override func resignFirstResponder() -> Bool {
        autocomplete.dismiss()
        // Invalid drafts remain visible so a click elsewhere cannot discard them.
        if session?.revision == revision { _ = session?.finish() }
        return super.resignFirstResponder()
    }
}
