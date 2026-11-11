import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct LogseqPageEditingTests {
    @Test func headingContinuationUsesBodyFontsAndLineHeights() throws {
        let source = "# Heading **bold**\nBody **bold** and `code`\nstatus:: open"
        let rendered = BlockRenderer.render(content: source, context: .init())
        let editor = BlockEditorTextView.create()
        editor.setContent(source)
        let focused = try #require(editor.textStorage)
        for text in [rendered, focused] {
            let ns = text.string as NSString
            let heading = ns.range(of: "Heading").location
            let body = ns.range(of: "Body").location
            let property = ns.range(of: "status").location
            let headingFont = try #require(text.attribute(.font, at: heading, effectiveRange: nil) as? NSFont)
            let bodyFont = try #require(text.attribute(.font, at: body, effectiveRange: nil) as? NSFont)
            let propertyFont = try #require(text.attribute(.font, at: property, effectiveRange: nil) as? NSFont)
            #expect(headingFont.pointSize == BlockRenderer.headingFont(level: 1).pointSize)
            #expect(bodyFont.pointSize == BlockRenderer.baseFontSize)
            #expect(propertyFont.pointSize == BlockRenderer.baseFontSize)
            let headingStyle = try #require(text.attribute(.paragraphStyle, at: heading, effectiveRange: nil) as? NSParagraphStyle)
            let bodyStyle = try #require(text.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle)
            #expect(headingStyle.maximumLineHeight == BlockRenderer.lineHeight(forSource: "# Heading"))
            #expect(bodyStyle.maximumLineHeight == BlockRenderer.lineHeight(forSource: ""))
        }
    }

    private func withPage(_ body: (AppState) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-logseq-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        let parsed = PageParser.parse("status:: open\r\n# Heading\r\n- body\r\n")
        let doc = PageDocument(name: "Logseq", blocks: parsed.blocks, preamble: parsed.preamble)
        store.updatePage(doc)
        try store.savePage(named: doc.name)
        let app = AppState(store: store)
        defer { app.shutdown() }
        try body(app)
    }

    @Test func headingUsesNormalEditorAndPropertyEditsUndoSeparately() throws {
        try withPage { app in
            let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
            controller.initialLayoutWidth = 600
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
            scroll.documentView = controller.tableView
            controller.tableView.frame.size = scroll.bounds.size
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            defer { controller.endEditing(); window.contentView = nil }
            controller.present(pageName: "Logseq", zoom: nil)
            window.layoutIfNeeded()
            let original = app.document(for: "Logseq")
            controller.focusBlock(try #require(original.blocks.first?.id), selection: nil)
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            #expect(editor.string == "# Heading")
            editor.insertText("# Edited", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            #expect(app.commitPagePreamble("status:: pending\r\n", for: "Logseq", expected: original.preamble))
            #expect(app.document(for: "Logseq").blocks[0].content == "# Edited")
            editor.insertText("# Later", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            app.undo()
            #expect(app.document(for: "Logseq").preamble == "status:: pending\r\n")
            #expect(app.document(for: "Logseq").blocks[0].content == "# Edited")
            app.undo()
            #expect(app.document(for: "Logseq").preamble == original.preamble)
            #expect(app.document(for: "Logseq").blocks[0].content == "# Edited")
            app.undo()
            #expect(app.document(for: "Logseq").blocks[0].content == "# Heading")
            app.redo()
            app.redo()
            #expect(app.document(for: "Logseq").preamble == "status:: pending\r\n")
            #expect(app.document(for: "Logseq").blocks[0].content == "# Edited")
            app.flushPendingSaves()
            let saved = try String(contentsOf: app.store.fileURL(forPageNamed: "Logseq"), encoding: .utf8)
            #expect(saved == "status:: pending\r\n- # Edited\n- body\r\n")
        }
    }

    @Test func propertyCommitRejectsStaleMetadataAndKeepsRecentBlockEdits() throws {
        try withPage { app in
            let original = app.document(for: "Logseq")
            var latest = original
            latest.blocks[1].content = "Changed elsewhere"
            app.commit(latest)
            #expect(app.commitPagePreamble("status:: changed\n", for: "Logseq", expected: original.preamble))
            #expect(app.document(for: "Logseq").blocks[1].content == "Changed elsewhere")
            #expect(!app.commitPagePreamble("status:: stale\n", for: "Logseq", expected: original.preamble))
            #expect(app.document(for: "Logseq").preamble == "status:: changed\n")
            app.undo()
            #expect(app.document(for: "Logseq").preamble == original.preamble)
            #expect(app.document(for: "Logseq").blocks[1].content == "Changed elsewhere")
        }
    }

    @Test func inlinePropertyEditingCommitsOnUndoAndKeepsInvalidDrafts() throws {
        try withPage { app in
            let session = PagePropertyEditSession()
            session.begin(app: app, pageName: "Logseq", index: 0)
            session.text = "status:: changed"
            app.undo()
            #expect(session.index == nil)
            #expect(app.document(for: "Logseq").preamble == "status:: open\r\n")
            app.redo()
            #expect(app.document(for: "Logseq").preamble == "status:: changed\r\n")
            session.begin(app: app, pageName: "Logseq", index: 0)
            session.text = "unfinished"
            #expect(!session.finish())
            #expect(session.error != nil)
            session.leave()
            let restored = PagePropertyEditSession()
            restored.restore(app: app, pageName: "Logseq")
            #expect(restored.text == "unfinished")
            #expect(restored.index == 0)
            restored.text = "status:: recovered"
            #expect(restored.finish())
            #expect(app.document(for: "Logseq").preamble == "status:: recovered\r\n")
        }
    }

    @Test func inlinePropertyConflictDoesNotOverwriteExternalChanges() throws {
        try withPage { app in
            let session = PagePropertyEditSession()
            session.begin(app: app, pageName: "Logseq", index: 0)
            session.text = "status:: local"
            var external = app.document(for: "Logseq")
            external.preamble = "status:: external\n"
            app.commit(external)
            #expect(!session.finish())
            #expect(session.conflicted)
            #expect(app.document(for: "Logseq").preamble == "status:: external\n")
            session.reload()
            #expect(session.text == "status:: external")
            #expect(!session.conflicted)
            #expect(session.finish())
        }
    }

    @Test func invalidPropertyDoesNotBlockSavingOrUndoingBlockEdits() throws {
        try withPage { app in
            let session = PagePropertyEditSession()
            session.begin(app: app, pageName: "Logseq", index: 0)
            session.text = "unfinished"
            var document = app.document(for: "Logseq")
            document.blocks[1].content = "Keep this edit"
            app.commit(document, undoLabel: "Test")
            app.flushPendingSaves()
            let saved = try String(contentsOf: app.store.fileURL(forPageNamed: "Logseq"), encoding: .utf8)
            #expect(saved.contains("Keep this edit"))
            app.undo()
            #expect(app.document(for: "Logseq").blocks[1].content == "body")
            app.redo()
            #expect(app.document(for: "Logseq").blocks[1].content == "Keep this edit")
            #expect(session.text == "unfinished")
            #expect(session.index == 0)
        }
    }

    @Test func clickingFollowingPropertyAfterDeletingDraftKeepsTarget() throws {
        try withPage { app in
            var document = app.document(for: "Logseq")
            document.preamble += "owner:: Alex\npriority:: high\n"
            app.commit(document)
            let session = PagePropertyEditSession()
            session.begin(app: app, pageName: "Logseq", index: 0)
            session.text = ""
            session.begin(app: app, pageName: "Logseq", index: 1)
            #expect(session.index == 0)
            #expect(session.text == "owner:: Alex")
        }
    }

    @Test func metadataAutocompleteTracksCaretAndPreservesFollowingTags() throws {
        let editor = PagePropertyTextView(usingTextLayoutManager: true)
        editor.autocomplete.pagePropertyEditing = true
        editor.autocomplete.fetchTags = { _ in ["project"] }
        editor.string = "tags:: pr, other"
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.autocomplete.textDidChange(in: editor)
        defer { editor.autocomplete.dismiss() }
        #expect(editor.autocomplete.isActive)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!editor.autocomplete.isActive)
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.autocomplete.textDidChange(in: editor)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        #expect(editor.autocomplete.handleKeyDown(try keyEvent(125)))
        #expect(editor.autocomplete.handleKeyDown(enter))
        #expect(editor.string == "tags:: project, other")
        #expect(!editor.autocomplete.isActive)
    }

    private func keyEvent(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    @Test func propertyContextClicksReachTheHostMenu() throws {
        final class MenuHost: NSResponder {
            var requests = 0
            override func rightMouseDown(with event: NSEvent) { requests += 1 }
        }
        let host = MenuHost()
        let view = RenderedTextView.create()
        view.nextResponder = host
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let controlClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1))
        view.rightMouseDown(with: rightClick)
        view.mouseDown(with: controlClick)
        #expect(host.requests == 2)
        var blockMenuRequests = 0
        view.onContextMenu = { _ in blockMenuRequests += 1 }
        view.rightMouseDown(with: rightClick)
        #expect(blockMenuRequests == 1)
        #expect(host.requests == 2)
    }

    @Test(arguments: [false, true])
    func propertyEditorTracksContentZoom(composing: Bool) async throws {
        let previousZoom = BlockRenderer.zoom
        defer { BlockRenderer.zoom = previousZoom }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-property-zoom-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "knopo-property-zoom-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let preferences = Preferences(defaults: defaults, syncsRenderer: false)
        let app = AppState(store: try GraphStore(root: root), preferences: preferences)
        defer { app.shutdown() }
        BlockRenderer.zoom = 1
        app.store.updatePage(PageDocument(name: "Test", preamble: "status:: open\ntags:: project\n"))
        let session = PagePropertyEditSession()
        let host = NSHostingView(rootView: PageMetadataView(pageName: "Test", session: session, addRequest: nil)
            .environmentObject(app).environmentObject(Navigator(app: app)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { session.leave(); window.contentView = nil }
        func settle() async throws {
            for _ in 0..<4 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        session.begin(app: app, pageName: "Test", index: 0)
        try await settle()
        let editor = try #require(window.firstResponder as? PagePropertyTextView)
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        if composing {
            editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let text = editor.string
        let selection = editor.selectedRange()
        let marked = editor.markedRange()
        for zoom: CGFloat in [1.5, 0.8, 1] {
            BlockRenderer.zoom = zoom
            preferences.zoom = zoom
            try await settle()
            let font = try #require(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(font.pointSize == BlockEditorTextView.editorFont.pointSize)
            #expect((editor.typingAttributes[.font] as? NSFont)?.pointSize == font.pointSize)
            #expect(editor.string == text)
            #expect(editor.selectedRange() == selection)
            #expect(editor.markedRange() == marked)
            #expect(window.firstResponder === editor)
            let layout = try #require(editor.textLayoutManager)
            layout.ensureLayout(for: layout.documentRange)
            #expect(editor.bounds.height >= ceil(layout.usageBoundsForTextContainer.height) + editor.textContainerInset.height * 2)
        }
        editor.unmarkText()
    }

    @Test func propertyLayoutFitsPlainTextAndPreservesComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-property-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: try GraphStore(root: root))
        defer { app.shutdown() }
        let session = PagePropertyEditSession()
        let host = NSHostingView(rootView: PageMetadataView(pageName: "Test", session: session, addRequest: nil)
            .environmentObject(app).environmentObject(Navigator(app: app)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { session.leave(); window.contentView = nil }
        session.begin(app: app, pageName: "Test", index: 0, inserting: true)
        func settle() async throws {
            for _ in 0..<4 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let editor = try #require(window.firstResponder as? PagePropertyTextView)
        let layout = try #require(editor.textLayoutManager)
        for source in ["status:: open", "description:: " + String(repeating: "**bold** `code` 👩🏽‍💻 中文 ", count: 8), "# unfinished property"] {
            editor.insertText(source, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            for width: CGFloat in [180, 500] {
                window.setContentSize(NSSize(width: width, height: 800))
                try await settle()
                layout.ensureLayout(for: layout.documentRange)
                let displayed = ceil(layout.usageBoundsForTextContainer.height) + editor.textContainerInset.height * 2
                #expect(editor.measuredHeight(forWidth: editor.bounds.width) == displayed)
                #expect(editor.bounds.height >= displayed)
                #expect(window.firstResponder === editor)
            }
        }
        editor.insertText("status:: ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let selection = editor.selectedRange()
        let source = editor.string
        for width: CGFloat in [180, 500] {
            window.setContentSize(NSSize(width: width, height: 800))
            try await settle()
            #expect(editor.hasMarkedText())
            #expect(editor.markedRange() == marked)
            #expect(editor.selectedRange() == selection)
            #expect(editor.string == source)
            #expect(window.firstResponder === editor)
        }
        editor.unmarkText()
        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle()
        #expect(editor.bounds.height >= NSLayoutManager().defaultLineHeight(for: BlockEditorTextView.editorFont))
    }

    @Test(arguments: [true, false])
    func propertyClickKeepsTargetAfterNativeFocusCommit(inserting: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-property-click-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: try GraphStore(root: root))
        defer { app.shutdown() }
        app.store.updatePage(PageDocument(name: "Test", preamble: "tags:: project\nstatus:: open\npriority:: high\n"))
        let session = PagePropertyEditSession()
        let host = NSHostingView(rootView: PageMetadataView(pageName: "Test", session: session, addRequest: nil)
            .environmentObject(app).environmentObject(Navigator(app: app)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { session.leave(); window.contentView = nil }
        session.begin(app: app, pageName: "Test", index: inserting ? 1 : 0, inserting: inserting)
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        func renderedViews(_ view: NSView) -> [RenderedTextView] {
            ((view as? RenderedTextView).map { [$0] } ?? []) + view.subviews.flatMap(renderedViews)
        }
        let target = try #require(renderedViews(host).first { $0.string == "status: open" })
        let editor = try #require(window.firstResponder as? PagePropertyTextView)
        editor.insertText(inserting ? "owner:: Alex" : "",
                          replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        // AppKit resigns the old editor before delivering the target's click.
        #expect(window.makeFirstResponder(target))
        #expect(session.index == nil)
        target.onFocusRequest(0)
        #expect(session.text == "status:: open")
        #expect(session.index == (inserting ? 2 : 0))
    }

    @Test func restoredDraftDoesNotTakeFocusOrCloseAnotherEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knopo-property-restore-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(store: try GraphStore(root: root))
        defer { app.shutdown() }
        let session = PagePropertyEditSession()
        session.begin(app: app, pageName: "Test", index: 0, inserting: true)
        session.text = "unfinished"
        session.leave()
        var closed = 0
        app.closePendingEdit = { closed += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container
        defer { session.leave(); window.contentView = nil }
        let block = BlockEditorTextView.create()
        container.addSubview(block)
        #expect(window.makeFirstResponder(block))
        session.restore(app: app, pageName: "Test")
        let metadata = PagePropertyTextView(usingTextLayoutManager: true)
        metadata.session = session
        metadata.revision = session.revision
        metadata.string = session.text
        container.addSubview(metadata)
        try await Task.sleep(for: .milliseconds(40))
        #expect(window.firstResponder === block)
        #expect(closed == 0)
        #expect(app.activeMetadataSession == nil)
        #expect(window.makeFirstResponder(metadata))
        #expect(closed == 1)
        #expect(session.requestsFocus)
        #expect(app.activeMetadataSession === session)
    }

    @Test func invalidDraftDoesNotUndoItsUnderlyingPageProperties() throws {
        try withPage { app in
            let session = PagePropertyEditSession()
            session.begin(app: app, pageName: "Logseq", index: 1, inserting: true)
            session.text = "tags:: project"
            session.enter()
            let before = app.document(for: "Logseq").preamble
            session.text = "mood good"
            app.undo()
            #expect(app.document(for: "Logseq").preamble == before)
            #expect(!session.conflicted)
            session.text = "mood:: good"
            #expect(session.finish())
            #expect(!session.conflicted)
            #expect(app.document(for: "Logseq").preamble.hasSuffix("mood:: good\r\n"))
        }
    }

    @Test func preambleKeepsFencesAndTagsMatchBlockDisplay() throws {
        let source = "Introduction\n\n```markdown\n# Example\nstatus:: code\n```"
        let document = PageDocument(name: "Test", preamble: "tags:: Project Alpha, [[Team A]]\n" + source)
        let rows = PageMetadataView.rows(in: document)
        #expect(rows.count == 2)
        guard case .text(let text) = rows.last else { Issue.record("Expected grouped preamble text"); return }
        #expect(text == source)
        let rendered = BlockRenderer.render(content: text, context: .init())
        let location = (rendered.string as NSString).range(of: "# Example").location
        #expect(location != NSNotFound)
        let font = try #require(rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize != BlockRenderer.headingFont(level: 1).pointSize)
        let tags = PageMetadataView.render(try #require(document.preambleProperties.first))
        let blockTags = BlockRenderer.render(content: "#[[Project Alpha]] #[[Team A]]", context: .init())
        #expect(tags.string == "tags: " + blockTags.string)
        #expect(tags.string.contains("#project alpha"))
        #expect(document.preamble.hasPrefix("tags:: Project Alpha, [[Team A]]"))
    }

    @Test func metadataCompletionDoesNotChangeUnselectedInput() throws {
        let editor = PagePropertyTextView(usingTextLayoutManager: true)
        editor.autocomplete.pagePropertyEditing = true
        editor.autocomplete.fetchTags = { _ in ["project"] }
        defer { editor.autocomplete.dismiss() }
        for text in ["tags::", "tags:: ", "tags:: alpha, ", "tags:: [[", "tags:: #"] {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            editor.autocomplete.textDidChange(in: editor)
            #expect(!editor.autocomplete.isActive)
        }
        for code in [UInt16(36), 76, 48] {
            editor.string = "tags:: proj"
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.autocomplete.textDidChange(in: editor)
            #expect(editor.autocomplete.isActive)
            #expect(!editor.autocomplete.handleKeyDown(try keyEvent(code)))
            #expect(editor.string == "tags:: proj")
            #expect(!editor.autocomplete.isActive)
        }
        editor.autocomplete.textDidChange(in: editor)
        #expect(editor.autocomplete.handleKeyDown(try keyEvent(125)))
        #expect(!editor.autocomplete.handleKeyDown(try keyEvent(48)))
        #expect(editor.string == "tags:: proj")
    }

    @Test func selectedMetadataCompletionAddsRequiredSeparatorSpace() throws {
        let editor = PagePropertyTextView(usingTextLayoutManager: true)
        editor.autocomplete.pagePropertyEditing = true
        editor.autocomplete.fetchTags = { _ in ["project", "prototype"] }
        defer { editor.autocomplete.dismiss() }
        editor.string = "tags::pr, other"
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.autocomplete.textDidChange(in: editor)
        #expect(editor.autocomplete.handleKeyDown(try keyEvent(125)))
        #expect(editor.autocomplete.handleKeyDown(try keyEvent(36)))
        #expect(editor.string == "tags:: project, other")
        #expect(PageParser.matchProperty(editor.string)?.value == "project, other")
    }

    @Test func blockTagCompletionStillAcceptsEnter() throws {
        let editor = BlockEditorTextView.create()
        let completion = AutocompleteController()
        completion.fetchTags = { _ in ["project"] }
        editor.setContent("#pr")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        completion.textDidChange(in: editor)
        defer { completion.dismiss() }
        #expect(completion.handleKeyDown(try keyEvent(36)))
        #expect(editor.string == "#project ")
    }

    @Test func tagPreviewIncludesPageAndBlockTags() throws {
        try withPage { app in
            let page = PageDocument(name: "Page tag", preamble: "tags:: project\n")
            let blockPage = PageDocument(name: "Block tag", blocks: [Block(content: "Work #project")])
            for document in [page, blockPage] {
                app.store.updatePage(document)
                try app.store.savePage(named: document.name)
            }
            let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
            let preview = try #require(controller.previewAttributedString(forTag: "project"))
            #expect(preview.string.contains("Page tag"))
            #expect(preview.string.contains("Block tag"))
            #expect(preview.string.contains("Work"))
        }
    }

    private func withEmptyPageEditor(
        _ body: (AppState, OutlineEditorController, PagePropertyEditSession, NSWindow) throws -> Void
    ) throws {
        try withPage { app in
            app.store.updatePage(PageDocument(name: "Logseq", blocks: [Block(content: "")]))
            let controller = OutlineEditorController(app: app, nav: Navigator(app: app))
            let metadata = PagePropertyEditSession()
            controller.pagePropertySession = metadata
            metadata.outline = controller
            controller.initialLayoutWidth = 600
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
            scroll.documentView = controller.tableView
            controller.tableView.frame.size = scroll.bounds.size
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            defer { metadata.leave(); controller.endEditing(); window.contentView = nil }
            controller.present(pageName: "Logseq", zoom: nil)
            window.layoutIfNeeded()
            controller.focusBlock(try #require(app.document(for: "Logseq").blocks.first?.id), selection: nil)
            try body(app, controller, metadata, window)
        }
    }

    @Test func firstPropertyStartsMetadataThenBlankLineReturnsToBody() throws {
        try withEmptyPageEditor { app, controller, metadata, window in
            let firstID = try #require(app.document(for: "Logseq").blocks.first?.id)
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            editor.insertText("tags:: project", replacementRange: editor.selectedRange())
            controller.editorSplit(atUTF16Offset: editor.string.utf16.count)
            #expect(app.document(for: "Logseq").preamble == "tags:: project\n")
            #expect(app.document(for: "Logseq").blocks.first?.id == firstID)
            #expect(app.document(for: "Logseq").blocks.first?.editableSource == "")
            #expect(metadata.index == 1)
            #expect(metadata.inserting)
            metadata.text = "status:: active"
            metadata.enter()
            #expect(metadata.index == 2)
            #expect(metadata.text.isEmpty)
            metadata.enter()
            #expect(metadata.index == nil)
            let body = try #require(window.firstResponder as? BlockEditorTextView)
            body.insertText("Body\nstatus:: block", replacementRange: body.selectedRange())
            controller.editorSplit(atUTF16Offset: body.string.utf16.count)
            let document = app.document(for: "Logseq")
            #expect(document.preamble == "tags:: project\nstatus:: active\n")
            #expect(document.blocks[0].content == "Body")
            #expect(document.blocks[0].properties == [BlockProperty(key: "status", value: "block")])
            app.flushPendingSaves()
            let saved = try String(contentsOf: app.store.fileURL(forPageNamed: "Logseq"), encoding: .utf8)
            #expect(saved.hasPrefix("tags:: project\nstatus:: active\n- Body\n"))
        }
    }

    @Test func firstPropertyConversionIsOneUndoStep() throws {
        try withEmptyPageEditor { app, controller, metadata, window in
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            editor.insertText("type:: project", replacementRange: editor.selectedRange())
            controller.editorSplit(atUTF16Offset: editor.string.utf16.count)
            #expect(metadata.inserting)
            app.undo()
            #expect(app.document(for: "Logseq").preamble.isEmpty)
            #expect(app.document(for: "Logseq").blocks[0].editableSource.isEmpty)
            app.redo()
            #expect(app.document(for: "Logseq").preamble == "type:: project\n")
            #expect(app.document(for: "Logseq").blocks[0].editableSource.isEmpty)
        }
    }

    @Test(arguments: ["existing", "later", "child", "zoom"])
    func propertyConversionDoesNotEscapeBlockScope(scope: String) throws {
        try withEmptyPageEditor { app, controller, metadata, window in
            controller.endEditing()
            let target = Block(content: scope == "existing" ? "Existing body" : "")
            let blocks: [Block]
            switch scope {
            case "later": blocks = [Block(content: "First"), target]
            case "child": blocks = [Block(content: "Parent", children: [target])]
            default: blocks = [target]
            }
            app.store.updatePage(PageDocument(name: "Logseq", blocks: blocks))
            controller.present(pageName: "Logseq", zoom: scope == "zoom" ? target.id : nil)
            controller.focusBlock(target.id, selection: nil)
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            editor.insertText("status:: block", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            controller.editorSplit(atUTF16Offset: editor.string.utf16.count)
            #expect(app.document(for: "Logseq").preamble.isEmpty)
            #expect(metadata.index == nil)
            #expect(app.document(for: "Logseq").blocks.flattened.contains {
                $0.properties.contains(BlockProperty(key: "status", value: "block"))
            })
        }
    }

    @Test func enterInExistingMetadataInsertsBeforeFollowingProperty() throws {
        try withPage { app in
            var document = app.document(for: "Logseq")
            document.preamble = "tags:: project\r\nstatus::  untouched\r\n"
            app.store.updatePage(document)
            let metadata = PagePropertyEditSession()
            metadata.begin(app: app, pageName: "Logseq", index: 0)
            metadata.enter()
            #expect(metadata.index == 1)
            #expect(metadata.inserting)
            metadata.text = "owner:: Alex"
            metadata.enter()
            #expect(app.document(for: "Logseq").preamble == "tags:: project\r\nowner:: Alex\r\nstatus::  untouched\r\n")
            #expect(metadata.index == 2)
            #expect(metadata.inserting)
            metadata.enter()
            #expect(metadata.index == nil)
            #expect(app.document(for: "Logseq").preambleProperties.count == 3)
        }
    }

    @Test func leavingOldTextViewDoesNotCommitTheNextDraft() throws {
        try withPage { app in
            let metadata = PagePropertyEditSession()
            metadata.begin(app: app, pageName: "Logseq", index: 0)
            let oldView = PagePropertyTextView(usingTextLayoutManager: true)
            oldView.session = metadata
            oldView.revision = metadata.revision
            metadata.enter()
            let nextRevision = metadata.revision
            _ = oldView.resignFirstResponder()
            #expect(metadata.revision == nextRevision)
            #expect(metadata.index == 1)
            #expect(metadata.inserting)
        }
    }

    @Test func backgroundFlushPreservesMetadataEditingAndBlankDrafts() throws {
        try withPage { app in
            let metadata = PagePropertyEditSession()
            metadata.begin(app: app, pageName: "Logseq", index: 0)
            metadata.text = "status:: active"
            let revision = metadata.revision
            app.flushPendingSaves()
            #expect(metadata.index == 0)
            #expect(metadata.revision == revision)
            #expect(metadata.text == "status:: active")
            #expect(app.document(for: "Logseq").preamble == "status:: active\r\n")
            metadata.enter()
            let draftRevision = metadata.revision
            app.flushPendingSaves()
            #expect(metadata.index == 1)
            #expect(metadata.revision == draftRevision)
            #expect(metadata.inserting)
            #expect(metadata.error == nil)
            metadata.text = "unfinished"
            app.flushPendingSaves()
            #expect(metadata.text == "unfinished")
            #expect(metadata.error == nil)
            metadata.text = "owner:: Alex"
            app.flushPendingSaves()
            #expect(metadata.index == 1)
            #expect(!metadata.inserting)
            #expect(app.document(for: "Logseq").preambleProperties.map(\.key) == ["status", "owner"])
            metadata.text = "owner:: New name"
            #expect(metadata.finish())
            #expect(app.document(for: "Logseq").preambleProperties.count == 2)
        }
    }

    @Test func reloadingInsertionKeepsDraftAndExistingRowsFollowTheirKey() throws {
        try withPage { app in
            let metadata = PagePropertyEditSession()
            metadata.begin(app: app, pageName: "Logseq", index: 0)
            var external = app.document(for: "Logseq")
            external.preamble = "tags:: new\nstatus:: changed\n"
            app.store.updatePage(external)
            #expect(!metadata.finish())
            metadata.reload()
            #expect(metadata.index == 1)
            #expect(metadata.text == "status:: changed")
            metadata.enter()
            metadata.text = "owner:: draft"
            external = app.document(for: "Logseq")
            external.preamble += "priority:: high\n"
            app.store.updatePage(external)
            #expect(!metadata.finish())
            metadata.reload()
            #expect(metadata.inserting)
            #expect(metadata.text == "owner:: draft")
            #expect(metadata.finish())
            #expect(app.document(for: "Logseq").preambleProperties.map(\.key) == ["tags", "status", "owner", "priority"])
        }
    }

    @Test func tabFromBlankInsertionEditsTheFollowingProperty() throws {
        try withPage { app in
            var document = app.document(for: "Logseq")
            document.preamble += "owner:: Alex\npriority:: high\n"
            app.store.updatePage(document)
            let metadata = PagePropertyEditSession()
            metadata.begin(app: app, pageName: "Logseq", index: 0)
            metadata.enter()
            metadata.move(by: 1)
            #expect(metadata.index == 1)
            #expect(!metadata.inserting)
            #expect(metadata.text == "owner:: Alex")
        }
    }
}
