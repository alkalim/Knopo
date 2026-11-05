import AppKit
import SwiftUI
import Testing
@testable import Knopo
import KnopoCore

@MainActor
@Suite struct BlockEditAnimationTests {
    @Test func selectionFollowsBlocksAcrossReloadAndClearsEveryFill() async throws {
        let blocks = [Block(content: "A"), Block(content: "B"), Block(content: "C")]
        try await withOutline(blocks: blocks) { app, controller, table, window in
            func selectedCells() -> Set<Int> {
                Set((0..<table.numberOfRows).filter {
                    (table.view(atColumn: 0, row: $0, makeIfNecessary: true)
                        as? OutlineRowCell)?.isSelectedBlock == true
                })
            }
            controller.selectViaClick(blocks[1].id, extend: false, toggle: false)
            #expect(selectedCells() == [1])
            let selection = controller.selectionMarkdown()
            var document = app.document(for: "Insertion")
            document.blocks.insert(Block(content: "Inserted before selection"), at: 0)
            app.commit(document)
            try await waitUntil { table.numberOfRows == 4 }
            try await settle(window)
            #expect(controller.selectionMarkdown() == selection)
            #expect(selectedCells() == [2])

            controller.selectViaClick(blocks[2].id, extend: true, toggle: false)
            #expect(selectedCells() == [2, 3])
            controller.selectViaClick(blocks[0].id, extend: false, toggle: false)
            #expect(selectedCells() == [1])
            let escape = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            table.keyDown(with: escape)
            #expect(selectedCells().isEmpty)
            #expect(controller.selectionMarkdown() == nil)
        }
    }

    @Test(arguments: [false, true])
    func deletingSelectedEmptyBlockKeepsFollowingRowHeights(reduceMotion: Bool) async throws {
        let empty = Block(content: "")
        let parent = Block(content: "Yet another block", children: [
            empty, Block(content: "Third block"),
            Block(content: String(repeating: "Use memory heap or alternative to store the in-memory RC; ", count: 4))
        ])
        try await withOutline(blocks: [Block(content: "My little block"), parent],
                              reduceMotion: reduceMotion) { app, controller, table, window in
            controller.focusBlock(empty.id, selection: NSRange(location: 0, length: 0))
            controller.selectViaClick(empty.id, extend: false, toggle: false)
            try await settle(window)
            #expect(controller.deleteSelection())
            try await settle(window)
            #expect(table.numberOfRows == 4)
            #expect(app.document(for: "Insertion").blocks[1].children.count == 2)
            for index in 0..<table.numberOfRows {
                let expected = controller.tableView(table, heightOfRow: index)
                #expect(abs(table.rect(ofRow: index).height - expected) < 1,
                        "Row \(index) has stale height")
                let row = try #require(table.rowView(atRow: index, makeIfNecessary: true))
                #expect(abs(row.frame.height - expected) < 1)
            }
        }
    }

    @Test func animationPreferenceAppliesToAnAlreadyOpenEditor() async throws {
        let name = "knopo-animation-preference-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults, syncsRenderer: false, reduceMotion: { true })
        try await withOutline(preferences: preferences) { app, controller, table, window in
            controller.focusBlock(app.document(for: "Insertion").blocks[0].id,
                                  selection: NSRange(location: 6, length: 0))
            preferences.animations = .off
            controller.editorSplit(atUTF16Offset: 6)
            #expect(table.numberOfRows == 4)
            #expect(animatedRows(table) == 0)
            try await settle(window)
            preferences.animations = .on
            controller.editorIndent()
            #expect(animatedRows(table) > 0)
            try await settle(window)
            preferences.animations = .system
            controller.editorOutdent()
            #expect(animatedRows(table) == 0)
            try await settle(window)
            preferences.animations = .on
            controller.editorDeleteEmptyBlock()
            #expect(table.numberOfRows == 3)
            #expect(table.blockEditAnimation.removalSnapshotCount == 1)
            try await settle(window)
        }
    }

    @Test(arguments: [0, 3, 6], [false, true])
    func enterAnimatesWithoutDelayingFocus(offset: Int, reduceMotion: Bool) async throws {
        try await withOutline(reduceMotion: reduceMotion) { app, controller, table, window in
            let before = app.document(for: "Insertion").blocks
            controller.focusBlock(before[0].id, selection: NSRange(location: offset, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            let following = try #require(table.rowView(atRow: 1, makeIfNecessary: true))
            let originalY = following.frame.minY
            try pressEnter(editor, window: window)

            let blocks = app.document(for: "Insertion").blocks
            #expect(table.numberOfRows == before.count + 1)
            #expect(window.firstResponder === editor)
            #expect(table.row(for: editor) == 1)
            #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
            #expect(blocks.prefix(2).map(\.content) == [String("Before".prefix(offset)),
                                                       String("Before".dropFirst(offset))])
            #expect(table.rowView(atRow: 2, makeIfNecessary: false) === following)
            #expect(following.frame.minY > originalY)
            #expect(hasAnimation(following) == !reduceMotion)
            let inserted = try #require(table.rowView(atRow: offset == 0 ? 0 : 1,
                                                       makeIfNecessary: false))
            #expect(hasAnimation(inserted) == !reduceMotion)
            if !reduceMotion {
                #expect(translation(following, axis: "y") == originalY - following.frame.minY)
                #expect(following.layer?.animation(forKey: BlockEditAnimation.animationKey)?.duration == 0.098)
            }
            try await settle(window)
            try await waitUntil { !hasAnimation(following) && !hasAnimation(inserted) }
            #expect(abs(following.frame.minY - table.rect(ofRow: 2).minY) < 1)
        }
    }

    @Test func enterAtEndAnimatesTheNewLastRow() async throws {
        try await withOutline(count: 1, reduceMotion: false) { app, controller, table, window in
            controller.focusBlock(app.document(for: "Insertion").blocks[0].id,
                                  selection: NSRange(location: 6, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            try pressEnter(editor, window: window)
            let inserted = try #require(table.rowView(atRow: 1, makeIfNecessary: false))
            #expect(hasAnimation(inserted))
            editor.insertText("New last row", replacementRange: editor.selectedRange())
            #expect(app.document(for: "Insertion").blocks[1].content == "New last row")
            try await settle(window)
            #expect(abs(table.frame.height - table.rect(ofRow: 1).maxY) < 1)
        }
    }

    @Test func rapidEntersSettleAnimationAndKeepEveryEdit() async throws {
        var animationTime: CFTimeInterval = 0
        try await withOutline(reduceMotion: false, animationClock: { animationTime }) { app, controller, table, window in
            let first = app.document(for: "Insertion").blocks[0]
            controller.focusBlock(first.id, selection: NSRange(location: 6, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            try pressEnter(editor, window: window)
            #expect(animatedRows(table) > 0)
            for index in 0..<20 {
                animationTime += 0.01
                try pressEnter(editor, window: window, repeatKey: true)
                #expect(table.numberOfRows == 5 + index)
                #expect(table.row(for: editor) == 2 + index)
                #expect(window.firstResponder === editor)
                #expect(animatedRows(table) == 0)
            }
            editor.insertText("Typed immediately", replacementRange: editor.selectedRange())
            #expect(app.document(for: "Insertion").blocks[21].content == "Typed immediately")
            try await settle(window)
            #expect(animatedRows(table) == 0)

            // The next row can be offscreen after the burst. Reveal the insertion
            // area so the animation check does not depend on caret scroll margins.
            let lastRow = table.numberOfRows - 1
            table.scrollRowToVisible(lastRow)
            try await waitUntil {
                window.layoutIfNeeded()
                return table.visibleRect.contains(table.rect(ofRow: lastRow))
            }
            // A pause restores the slide; the burst does not disable it permanently.
            animationTime += 1
            try pressEnter(editor, window: window)
            #expect(animatedRows(table) > 0)
            #expect(table.row(for: editor) == 22)
            controller.editorMergeWithPrevious()
            #expect(animatedRows(table) == 0)
            #expect(app.document(for: "Insertion").blocks.count == 24)
        }
    }

    @Test func largeSharedOutlineOnlyAnimatesVisibleRows() async throws {
        try await withOutline(count: 400, shared: true, reduceMotion: false, animationClock: { 0 }) {
            app, controller, table, window in
            controller.focusBlock(app.document(for: "Insertion").blocks[0].id,
                                  selection: NSRange(location: 3, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            var bottomRow: NSTableRowView?
            table.enumerateAvailableRowViews { view, _ in
                if view.frame.intersects(table.visibleRect),
                   view.frame.minY > (bottomRow?.frame.minY ?? -.infinity) {
                    bottomRow = view
                }
            }
            let leavingRow = try #require(bottomRow)
            try pressEnter(editor, window: window)
            var liveRows = 0
            table.enumerateAvailableRowViews { _, _ in liveRows += 1 }
            #expect(table.numberOfRows == 401)
            #expect(liveRows < 100)
            #expect(animatedRows(table) < 30)
            #expect(animatedRows(table) > 0)
            #expect(!leavingRow.frame.intersects(table.visibleRect))
            #expect(hasAnimation(leavingRow))
            controller.editorIndent()
            #expect(animatedRows(table) == 0)
            #expect(window.firstResponder === editor)
            try await settle(window)
        }
    }

    @Test func wrappedSplitAndImmediateUndoKeepLayoutAndText() async throws {
        try await withOutline { app, controller, table, window in
            let first = app.document(for: "Insertion").blocks[0]
            controller.focusBlock(first.id, selection: NSRange(location: 6, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            let text = String(repeating: "wrapped words ", count: 40)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: 6))
            editor.setSelectedRange(NSRange(location: 14, length: 0))
            try pressEnter(editor, window: window)
            #expect(app.document(for: "Insertion").blocks.prefix(2).map(\.content).joined() == text)
            #expect(table.row(for: editor) == 1)
            app.undo()
            try await settle(window)
            #expect(app.document(for: "Insertion").blocks[0].content == text)
            #expect(table.numberOfRows == 3)
            try await waitUntil { animatedRows(table) == 0 }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func indentAndOutdentMoveDescendantsAndKeepTheCaret(reduceMotion: Bool, typingFirst: Bool) async throws {
        let child = Block(content: "Child", children: [Block(content: "Grandchild")])
        let target = Block(content: String(repeating: "Words that wrap around the row. ", count: 4),
                           children: [child])
        let blocks = [Block(content: "Parent"), target, Block(content: "After")]
        var time: CFTimeInterval = 0
        try await withOutline(blocks: blocks, reduceMotion: reduceMotion, animationClock: { time }) {
            app, controller, table, window in
            controller.focusBlock(target.id, selection: NSRange(location: 3, length: 2))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            if typingFirst {
                editor.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
                editor.setSelectedRange(NSRange(location: 3, length: 2))
            }
            let content = editor.string
            try await settle(window)
            let editorHost = editor.superview
            let cells = (0...4).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) }
            try #require(cells.count == 5)
            let edits = StorageEdits()
            NotificationCenter.default.addObserver(
                edits, selector: #selector(StorageEdits.didEdit(_:)),
                name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
            defer { NotificationCenter.default.removeObserver(edits) }
            for outdent in [false, true] {
                time += 1
                if outdent { controller.editorOutdent() } else { controller.editorIndent() }
                let document = app.document(for: "Insertion")
                #expect(document.blocks.path(to: target.id) == (outdent ? [1] : [0, 0]))
                #expect(document.blocks.path(to: child.id) == (outdent ? [1, 0] : [0, 0, 0]))
                #expect(window.firstResponder === editor)
                #expect(editor.string == content)
                #expect(document.blocks.block(id: target.id)?.content == content)
                #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
                #expect(editor.superview === editorHost)
                #expect(edits.count == 0)
                for (index, cell) in cells.enumerated() {
                    #expect(table.view(atColumn: 0, row: index, makeIfNecessary: false) === cell)
                }
                for row in 1...3 {
                    let view = try #require(table.rowView(atRow: row, makeIfNecessary: false))
                    if reduceMotion {
                        #expect(!hasAnimation(view))
                    } else {
                        #expect(translation(view, axis: "x") ==
                                (outdent ? 1 : -1) * OutlineRowCell.indentPerDepth)
                        #expect(view.layer?.animation(forKey: BlockEditAnimation.animationKey)?.duration == 0.075)
                    }
                }
                try await settle(window)
                #expect(abs(table.rect(ofRow: 1).height - controller.tableView(table, heightOfRow: 1)) < 1)
                #expect(abs(table.frame.height - table.rect(ofRow: 4).maxY) < 1)
            }
        }
    }

    @Test(arguments: [false, true])
    func deletingTheLastEmptyBlockRestoresFocusImmediately(reduceMotion: Bool) async throws {
        let blocks = [Block(content: "Before"), Block(content: "")]
        try await withOutline(blocks: blocks, reduceMotion: reduceMotion) {
            app, controller, table, window in
            controller.focusBlock(blocks[1].id, selection: NSRange(location: 0, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            let clip = try #require(table.enclosingScrollView?.contentView)
            let removedRow = try #require(table.rowView(atRow: 1, makeIfNecessary: false))
            let removedFrame = removedRow.convert(removedRow.bounds, to: clip)
            controller.editorDeleteEmptyBlock()
            #expect(table.numberOfRows == 1)
            #expect(app.document(for: "Insertion").blocks.map(\.id) == [blocks[0].id])
            #expect(window.firstResponder === editor)
            #expect(table.row(for: editor) == 0)
            #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
            #expect(table.blockEditAnimation.removalSnapshotCount == (reduceMotion ? 0 : 1))
            if !reduceMotion {
                let overlay = try #require(clip.subviews.compactMap {
                    $0 as? BlockEditAnimation.RemovalOverlay
                }.first)
                let image = try #require(overlay.images.first)
                #expect(overlay.convert(image.frame, to: clip) == removedFrame)
                #expect(image.image.size == removedFrame.size)
                #expect(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == nil)
                #expect(overlay.accessibilityChildren()?.isEmpty == true)
            }
            editor.insertText(" typed", replacementRange: editor.selectedRange())
            #expect(app.document(for: "Insertion").blocks[0].content == "Before typed")
            try await settle(window)
            try await waitUntil { table.blockEditAnimation.removalSnapshotCount == 0 }
            #expect(abs(table.frame.height - table.intrinsicContentSize.height) < 1)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func mergingIntoAnEmptyBlockSlidesTheTextFromItsOldRow(forward: Bool, reduceMotion: Bool) async throws {
        let text = String(repeating: "Words that wrap around the row. ", count: 4)
        let source = Block(content: text)
        let receiver = Block(content: "", children: forward ? [source] : [])
        let after = Block(content: "After")
        // Forward Delete also covers a merge from a child into its empty parent.
        let blocks = [Block(content: "Before"), receiver] + (forward ? [] : [source]) + [after]
        try await withOutline(blocks: blocks, reduceMotion: reduceMotion) {
            app, controller, table, window in
            controller.focusBlock(forward ? receiver.id : source.id,
                                  selection: NSRange(location: 0, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            let oldTextY = table.rect(ofRow: 2).minY
            let oldAfterY = table.rect(ofRow: 3).minY
            let emptyHeight = table.rect(ofRow: 1).height
            editor.doCommand(by: forward ? #selector(NSResponder.deleteForward(_:))
                                        : #selector(NSResponder.deleteBackward(_:)))
            #expect(app.document(for: "Insertion").blocks.map(\.id) ==
                    [blocks[0].id, receiver.id, after.id])
            #expect(editor.string == text)
            #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
            #expect(window.firstResponder === editor)
            #expect(table.row(for: editor) == 1)
            let moved = try #require(table.rowView(atRow: 1, makeIfNecessary: false))
            let following = try #require(table.rowView(atRow: 2, makeIfNecessary: false))
            if reduceMotion {
                #expect(!hasAnimation(moved))
                #expect(!hasAnimation(following))
            } else {
                #expect(translation(moved, axis: "y") == oldTextY - moved.frame.minY)
                if forward { #expect(translation(moved, axis: "x") == OutlineRowCell.indentPerDepth) }
                #expect(translation(following, axis: "y") == oldAfterY - following.frame.minY)
                #expect(moved.layer?.animation(forKey: BlockEditAnimation.animationKey)?.duration == 0.098)
                let overlay = try #require(table.enclosingScrollView?.contentView.subviews.compactMap {
                    $0 as? BlockEditAnimation.RemovalOverlay
                }.first)
                // Only the empty row fades. The moving text must not leave a duplicate behind.
                #expect(overlay.images.count == 1)
                #expect(overlay.images.first?.frame.height == emptyHeight)
                #expect(overlay.layer?.animation(forKey: BlockEditAnimation.animationKey)?.duration == 0.098)
            }
            editor.insertText("Typed ", replacementRange: editor.selectedRange())
            #expect(app.document(for: "Insertion").blocks[1].content == "Typed " + text)
            try await settle(window)
            try await waitUntil {
                !hasAnimation(moved) && table.blockEditAnimation.removalSnapshotCount == 0
            }
        }
    }

    @Test func deletingALargeSubtreeOnlySnapshotsTheViewport() async throws {
        let parent = Block(content: "Parent", children: (0..<400).map { Block(content: "Child \($0)") })
        let blocks = [parent, Block(content: "After")]
        try await withOutline(blocks: blocks, shared: true, reduceMotion: false) {
            app, controller, table, window in
            controller.selectViaClick(parent.id, extend: false, toggle: false)
            #expect(controller.deleteSelection())
            #expect(app.document(for: "Insertion").blocks.map(\.content) == ["After"])
            #expect(table.numberOfRows == 1)
            #expect(controller.selectionMarkdown() == nil)
            #expect(table.blockEditAnimation.removalSnapshotCount > 0)
            #expect(table.blockEditAnimation.removalSnapshotCount < 30)
            try await settle(window)
            try await waitUntil { table.blockEditAnimation.removalSnapshotCount == 0 }
        }
    }

    @Test func mergesAndMixedRapidEditsNeverQueueAnimations() async throws {
        let blocks = [Block(content: "Alpha"), Block(content: "Beta"), Block(content: "After")]
        var time: CFTimeInterval = 0
        try await withOutline(blocks: blocks, reduceMotion: false, animationClock: { time }) {
            app, controller, table, window in
            controller.focusBlock(blocks[1].id, selection: NSRange(location: 0, length: 0))
            let editor = try #require(window.firstResponder as? BlockEditorTextView)
            controller.editorMergeWithPrevious()
            #expect(editor.string == "AlphaBeta")
            #expect(editor.selectedRange() == NSRange(location: 5, length: 0))
            #expect(table.numberOfRows == 2)
            #expect(table.blockEditAnimation.removalSnapshotCount == 1)
            #expect(animatedRows(table) > 0)
            time += 0.01
            controller.editorSplit(atUTF16Offset: 5)
            #expect(table.blockEditAnimation.removalSnapshotCount == 0)
            #expect(animatedRows(table) == 0)
            for _ in 0..<10 {
                time += 0.01
                controller.editorIndent()
                #expect(animatedRows(table) == 0)
                time += 0.01
                controller.editorOutdent()
                #expect(animatedRows(table) == 0)
            }
            #expect(app.document(for: "Insertion").blocks.map(\.content) == ["Alpha", "Beta", "After"])
            #expect(window.firstResponder === editor)
            time += 1
            controller.editorMergeWithNext()
            #expect(editor.string == "BetaAfter")
            #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
            #expect(table.blockEditAnimation.removalSnapshotCount == 1)
            app.undo()
            try await settle(window)
            #expect(app.document(for: "Insertion").blocks.map(\.content) == ["Alpha", "Beta", "After"])
            try await waitUntil { table.blockEditAnimation.removalSnapshotCount == 0 }
        }
    }

    @Test func selectedRunsAnimateBothDirectionsAndKeepSelection() async throws {
        let blocks = [Block(content: "Parent"),
                      Block(content: "A", children: [Block(content: "A child")]),
                      Block(content: "B", children: [Block(content: "B child")]),
                      Block(content: "After")]
        var time: CFTimeInterval = 0
        try await withOutline(blocks: blocks, reduceMotion: false, animationClock: { time }) {
            app, controller, table, window in
            controller.selectViaClick(blocks[1].id, extend: false, toggle: false)
            controller.selectViaClick(blocks[2].id, extend: false, toggle: true)
            let selection = controller.selectionMarkdown()
            let cells = (0...5).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) }
            try #require(cells.count == 6)
            for outdent in [false, true] {
                time += 1
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: outdent ? [.shift] : [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
                table.keyDown(with: event)
                #expect(controller.selectionMarkdown() == selection)
                for (index, cell) in cells.enumerated() {
                    #expect(table.view(atColumn: 0, row: index, makeIfNecessary: false) === cell)
                }
                #expect(app.document(for: "Insertion").blocks[0].children.count == (outdent ? 0 : 2))
                for row in 1...4 {
                    let view = try #require(table.rowView(atRow: row, makeIfNecessary: false))
                    let group = try #require(view.layer?.animation(forKey: BlockEditAnimation.animationKey)
                        as? CAAnimationGroup)
                    #expect(group.animations?.contains {
                        ($0 as? CABasicAnimation)?.keyPath == "transform.translation.x"
                    } == false)
                    #expect(translation(view, axis: "x") ==
                            (outdent ? 1 : -1) * OutlineRowCell.indentPerDepth)
                }
                try await settle(window)
            }
        }
    }

    @Test func resizeAndDetachRemoveTheDeletionOverlay() async throws {
        let blocks = [Block(content: "One"), Block(content: "Two"), Block(content: "Three")]
        var time: CFTimeInterval = 0
        try await withOutline(blocks: blocks, reduceMotion: false, animationClock: { time }) {
            _, controller, table, window in
            controller.focusBlock(blocks[0].id, selection: NSRange(location: 0, length: 0))
            controller.editorMergeWithNext()
            #expect(table.blockEditAnimation.removalSnapshotCount == 1)
            table.setFrameSize(NSSize(width: table.frame.width - 10, height: table.frame.height))
            #expect(table.blockEditAnimation.removalSnapshotCount == 0)
            #expect(animatedRows(table) == 0)
            time += 1
            controller.editorMergeWithNext()
            #expect(table.blockEditAnimation.removalSnapshotCount == 1)
            window.contentView = nil
            #expect(table.blockEditAnimation.removalSnapshotCount == 0)
        }
    }

    @Test func indentingIntoCollapsedParentKeepsSelectionOnTheMovedBlocks() async throws {
        let parent = Block(content: "Parent", children: [Block(content: "Hidden child")], collapsed: true)
        let blocks = [parent, Block(content: "A"), Block(content: "B"), Block(content: "After")]
        try await withOutline(blocks: blocks, reduceMotion: false) { app, controller, table, window in
            controller.selectViaClick(blocks[1].id, extend: false, toggle: false)
            controller.selectViaClick(blocks[2].id, extend: false, toggle: true)
            let selection = controller.selectionMarkdown()
            let cells = (1...2).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) }
            try #require(cells.count == 2)
            for outdent in [false, true] {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: outdent ? [.shift] : [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
                table.keyDown(with: event)
                #expect(controller.selectionMarkdown() == selection)
                #expect(table.numberOfRows == 5)
                #expect(!app.document(for: "Insertion").blocks[0].collapsed)
                for (offset, cell) in cells.enumerated() {
                    #expect(table.view(atColumn: 0, row: offset + 2, makeIfNecessary: false) === cell)
                }
                try await settle(window)
            }
        }
    }

    @Test func timeSpentInLayoutDoesNotCountAsAPauseBetweenEdits() async throws {
        var time: CFTimeInterval = 0
        try await withOutline(reduceMotion: false, animationClock: { time }) {
            app, controller, table, window in
            controller.focusBlock(app.document(for: "Insertion").blocks[0].id,
                                  selection: NSRange(location: 6, length: 0))
            let onLayout = table.onDidLayout
            table.onDidLayout = {
                onLayout?()
                time = 0.4
            }
            controller.editorSplit(atUTF16Offset: 6)
            table.onDidLayout = onLayout
            try #require(time == 0.4)
            #expect(animatedRows(table) > 0)
            time = 0.41
            controller.editorIndent()
            #expect(animatedRows(table) == 0)
            time = 1
            controller.editorOutdent()
            #expect(animatedRows(table) > 0)
            try await settle(window)
        }
    }

    @Test func newlyRevealedRowsFollowTheUpwardSlideAfterDeletion() async throws {
        try await withOutline(count: 100, shared: true, reduceMotion: false) {
            app, controller, table, window in
            controller.selectViaClick(app.document(for: "Insertion").blocks[0].id,
                                      extend: false, toggle: false)
            let visibleRange = table.rows(in: table.visibleRect)
            let enteringIndex = visibleRange.location + visibleRange.length
            let oldFrame = table.rect(ofRow: enteringIndex)
            try #require(!oldFrame.intersects(table.visibleRect))
            #expect(controller.deleteSelection())
            let entering = try #require(table.rowView(atRow: enteringIndex - 1,
                                                       makeIfNecessary: false))
            #expect(entering.frame.intersects(table.visibleRect))
            #expect(translation(entering, axis: "y") == oldFrame.minY - entering.frame.minY)
            try await settle(window)
        }
    }

    @Test func deletionSnapshotKeepsItsPositionInAScrolledOutline() async throws {
        try await withOutline(count: 100, shared: true, reduceMotion: false) {
            app, controller, table, window in
            controller.focusBlock(app.document(for: "Insertion").blocks[40].id,
                                  selection: NSRange(location: 0, length: 0))
            try await settle(window)
            let clip = try #require(table.enclosingScrollView?.contentView)
            try #require(clip.bounds.minY > 0)
            let removed = try #require(table.rowView(atRow: 40, makeIfNecessary: false))
            let rect = removed.convert(table.visibleRect.intersection(removed.frame), from: table)
            let expected = removed.convert(rect, to: clip)
            controller.editorMergeWithPrevious()
            let overlay = try #require(clip.subviews.compactMap {
                $0 as? BlockEditAnimation.RemovalOverlay
            }.first)
            let image = try #require(overlay.images.first)
            #expect(overlay.convert(image.frame, to: clip) == expected)
            let bitmap = try #require(image.image.representations.first as? NSBitmapImageRep)
            var textPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.5 {
                        textPixels += 1
                    }
                }
            }
            // The row's selection tint is translucent. The text supplies opaque pixels.
            #expect(textPixels > 50)
            try await settle(window)
            try await waitUntil { table.blockEditAnimation.removalSnapshotCount == 0 }
        }
    }

    private func translation(_ view: NSTableRowView, axis: String) -> CGFloat? {
        if axis == "x" {
            let cell = view.subviews.compactMap { $0 as? OutlineRowCell }.first
            let slide = cell?.indentationAnimationViews.first?.layer?
                .animation(forKey: BlockEditAnimation.animationKey) as? CABasicAnimation
            return (slide?.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        let group = view.layer?.animation(forKey: BlockEditAnimation.animationKey) as? CAAnimationGroup
        let slide = group?.animations?.compactMap { $0 as? CABasicAnimation }
            .first { $0.keyPath == "transform.translation.\(axis)" }
        return (slide?.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private final class StorageEdits: NSObject {
        var count = 0
        @objc func didEdit(_ notification: Notification) { count += 1 }
    }

    private func hasAnimation(_ view: NSTableRowView) -> Bool {
        func hasAnimation(_ layer: CALayer) -> Bool {
            layer.animation(forKey: BlockEditAnimation.animationKey) != nil
                || (layer.sublayers ?? []).contains(where: hasAnimation)
        }
        return view.layer.map(hasAnimation) ?? false
    }

    private func animatedRows(_ table: OutlineTableView) -> Int {
        var count = 0
        table.enumerateAvailableRowViews { view, _ in
            if hasAnimation(view) { count += 1 }
        }
        return count
    }

    private func pressEnter(_ editor: BlockEditorTextView, window: NSWindow,
                            repeatKey: Bool = false) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: 36))
        editor.keyDown(with: event)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func withOutline(
        count: Int = 3, blocks: [Block]? = nil, shared: Bool = false,
        reduceMotion: Bool? = nil, animationClock: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        preferences: Preferences? = nil,
        _ body: (AppState, OutlineEditorController, OutlineTableView, NSWindow) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knopo-insertion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try GraphStore(root: root)
        var page = try store.createPage(named: "Insertion")
        page.blocks = blocks ?? ([Block(content: "Before")]
            + (1..<count).map { Block(content: "Following \($0)") })
        store.updatePage(page)
        let app = AppState(store: store, preferences: preferences ?? .standard)
        defer { app.shutdown() }
        let nav = Navigator(app: app)
        let host = NSHostingView(rootView: ScrollView {
            OutlineEditorView(pageName: page.name, inPane: shared)
                .environmentObject(app).environmentObject(nav)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Knopo Insertion Animation Test"
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        defer { window.contentView = nil }
        try await settle(window)
        let table = try #require(descendants(host, of: OutlineTableView.self).first)
        if preferences == nil {
            table.blockEditAnimation = BlockEditAnimation(
                currentTime: animationClock, reducesMotion: {
                    reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                })
        }
        let controller = try #require(table.delegate as? OutlineEditorController)
        defer { controller.endEditing() }
        try await body(app, controller, table, window)
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }
}
