import AppKit
import SwiftUI

/// AppKit owns scrolling, row reuse, and document layout.
struct JournalScrollView: NSViewRepresentable {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    let days: [String]

    func makeCoordinator() -> Coordinator { Coordinator(app: app, nav: nav) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = context.coordinator.table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(days: days, focusToken: nav.focusWritingToken)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = JournalTableView()
        let app: AppState
        let nav: Navigator
        var days: [String] = []
        var focusToken = 0
        var heights: [String: CGFloat] = [:]
        // Returning to today must not repeat its initial automatic writing focus.
        var todayHost: JournalDayHost?

        init(app: AppState, nav: Navigator) {
            self.app = app
            self.nav = nav
            focusToken = nav.focusWritingToken
            super.init()
            table.headerView = nil
            table.backgroundColor = .clear
            table.style = .plain
            table.selectionHighlightStyle = .none
            table.refusesFirstResponder = true
            table.focusRingType = .none
            table.intercellSpacing = .zero
            table.rowHeight = 320
            table.usesAutomaticRowHeights = true
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            let column = NSTableColumn(identifier: .init("day"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.delegate = self
            table.dataSource = self
        }

        func update(days newDays: [String], focusToken newToken: Int) {
            if days != newDays {
                let oldDays = days
                let oldSet = Set(oldDays)
                let newSet = Set(newDays)
                if !oldDays.isEmpty {
                    OutlineScrollAnchor.preserve(beforeResizing: table, widthChanged: true)
                }
                if oldDays.first != newDays.first {
                    todayHost?.identifier = .init("day")
                    todayHost = nil
                }
                days = newDays
                heights = heights.filter { newSet.contains($0.key) }
                table.beginUpdates()
                table.removeRows(at: IndexSet(oldDays.indices.filter { !newSet.contains(oldDays[$0]) }.map { $0 + 1 }), withAnimation: [])
                table.insertRows(at: IndexSet(newDays.indices.filter { !oldSet.contains(newDays[$0]) }.map { $0 + 1 }), withAnimation: [])
                table.endUpdates()
            }
            if focusToken != newToken, !days.isEmpty {
                focusToken = newToken
                if table.view(atColumn: 0, row: 1, makeIfNecessary: false) == nil {
                    table.scrollRowToVisible(1)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { days.count + 2 }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // Native spacer rows keep document padding separate from toolbar insets.
            guard days.indices.contains(row - 1) else { return 20 }
            return heights[days[row - 1]] ?? tableView.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard days.indices.contains(row - 1) else { return nil }
            if row == 1, let todayHost { return todayHost }
            let identifier = NSUserInterfaceItemIdentifier("day")
            let day = days[row - 1]
            let content = AnyView(JournalDay(day: day, outlineWidth: max(100, tableView.bounds.width - 40))
                .padding(.horizontal, 20)
                .environmentObject(app).environmentObject(nav))
            let host: JournalDayHost
            if row != 1, let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? JournalDayHost {
                host = reused
                host.heightChanged = nil
                host.rootView = content
            } else {
                host = JournalDayHost(rootView: content)
                host.sizingOptions = [.intrinsicContentSize]
                host.safeAreaRegions = []
            }
            // Today is retained separately and must not also enter the reuse pool.
            host.identifier = row == 1 ? nil : identifier
            if host.measuredHeight == nil {
                host.measuredHeight = host.heightAnchor.constraint(equalToConstant: heights[day] ?? 320)
                host.measuredHeight?.isActive = true
            } else {
                host.measuredHeight?.constant = heights[day] ?? 320
            }
            host.invalidateIntrinsicContentSize()
            if row == 1 { todayHost = host }
            host.restoreEditing = { [weak self] page, state in self?.restoreEditing(state, on: page) }
            host.heightChanged = { [weak self, weak host] height in
                guard let self, let host else { return }
                let row = self.table.row(for: host)
                guard self.days.indices.contains(row - 1), self.days[row - 1] == day,
                      abs((self.heights[day] ?? self.table.rowHeight) - height) > 0.5 else { return }
                host.measuredHeight?.constant = height
                self.heights[day] = height
            }
            return host
        }

        private func restoreEditing(_ state: OutlineEditorSnapshot, on day: String) {
            guard table.window != nil else { return }
            // Undo can bring an empty past day back into the feed.
            update(days: app.journalDays(), focusToken: nav.focusWritingToken)
            guard let index = days.firstIndex(of: day) else { return }
            table.scrollRowToVisible(index + 1)
            // Restore on the editor that AppKit supplies for this day after reuse.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.table.window != nil, let index = self.days.firstIndex(of: day) else { return }
                self.table.layoutSubtreeIfNeeded()
                guard let host = self.table.view(atColumn: 0, row: index + 1, makeIfNecessary: true) else { return }
                host.layoutSubtreeIfNeeded()
                @MainActor func outline(in view: NSView) -> OutlineEditorController? {
                    if let table = view as? OutlineTableView { return table.delegate as? OutlineEditorController }
                    return view.subviews.lazy.compactMap { outline(in: $0) }.first
                }
                guard let controller = outline(in: host) else { return }
                controller.present(pageName: day, zoom: nil)
                controller.restoreEditing(state, onPage: day)
            }
        }
    }
}

/// Tell the table when SwiftUI or an embedded outline changes a day's height.
final class JournalDayHost: NSHostingView<AnyView> {
    var heightChanged: ((CGFloat) -> Void)?
    private var needsHeightUpdate = true
    // A concrete constraint lets AppKit track embedded outline height changes.
    var measuredHeight: NSLayoutConstraint?
    var restoreEditing: ((String, OutlineEditorSnapshot) -> Void)?

    static func restorer(for day: String, containing view: NSView) -> ((OutlineEditorSnapshot?) -> Void)? {
        var ancestor: NSView? = view
        while let current = ancestor {
            if let restore = (current as? JournalDayHost)?.restoreEditing {
                return { state in if let state { restore(day, state) } }
            }
            ancestor = current.superview
        }
        return nil
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        needsHeightUpdate = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard needsHeightUpdate else { return }
        needsHeightUpdate = false
        heightChanged?(ceil(max(1, intrinsicContentSize.height)))
    }
}

final class JournalTableView: NSTableView {
    override func accessibilityChildren() -> [Any]? {
        // Keep accessibility discovery from constructing every day's editor.
        let accessibility = self as NSAccessibilityProtocol
        var children = accessibility.accessibilityVisibleRows() ?? []
        if let editor = window?.firstResponder as? NSView, editor.isDescendant(of: self) {
            let row = row(for: editor)
            if row >= 0, let rows = accessibility.accessibilityRows(), row < rows.count {
                let focused = rows[row] as AnyObject
                if !children.contains(where: { ($0 as AnyObject) === focused }) { children.append(focused) }
            }
        }
        return children
    }
}
