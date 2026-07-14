import Foundation

/// Structural outline operations (SPEC §5.4, §13). All operate on a forest of
/// top-level blocks and take/return index paths. Depth-changing moves
/// invalidate raw source so the serializer re-indents canonically.
public enum OutlineOps {

    /// A row in the flattened visible outline (respects `collapsed` and zoom).
    public struct VisibleRow: Identifiable, Sendable {
        public var block: Block
        public var depth: Int
        public var path: [Int]
        public var hasChildren: Bool
        public var id: UUID { block.id }
    }

    /// Flattens the forest for display. When `zoomRoot` is set, that block
    /// becomes the temporary page root (its subtree only, itself at depth -1
    /// shown as the zoom header by the UI; rows start at its children).
    public static func visibleRows(
        in blocks: [Block], zoomRoot: UUID? = nil
    ) -> [VisibleRow] {
        var scope: [Block] = blocks
        var basePath: [Int] = []
        if let zoomRoot, let path = blocks.path(to: zoomRoot),
           let root = blocks.block(at: path) {
            scope = root.children
            basePath = path
        }
        var rows: [VisibleRow] = []
        func walk(_ list: [Block], depth: Int, prefix: [Int]) {
            for (i, block) in list.enumerated() {
                let path = prefix + [i]
                rows.append(VisibleRow(
                    block: block, depth: depth, path: path,
                    hasChildren: !block.children.isEmpty
                ))
                if !block.collapsed {
                    walk(block.children, depth: depth + 1, prefix: path)
                }
            }
        }
        walk(scope, depth: 0, prefix: basePath)
        return rows
    }

    /// Inserts a new empty block as the next sibling (Enter). If the reference
    /// block has visible children, the new block becomes its first child
    /// instead (matching outliner convention). Returns the new block's id.
    @discardableResult
    public static func insertBlockAfter(
        _ path: [Int], in blocks: inout [Block], content: String = ""
    ) -> UUID {
        let new = Block(content: content)
        if let block = blocks.block(at: path), !block.children.isEmpty, !block.collapsed {
            blocks.update(at: path) { $0.children.insert(new, at: 0) }
        } else {
            var sibling = path
            sibling[sibling.count - 1] += 1
            blocks.insert(new, at: sibling)
        }
        return new.id
    }

    /// Tab: block becomes the last child of its previous sibling.
    @discardableResult
    public static func indent(_ path: [Int], in blocks: inout [Block]) -> Bool {
        guard let last = path.last, last > 0 else { return false }
        guard var moved = blocks.remove(at: path) else { return false }
        moved.invalidateRaw(deep: true)
        var prevSibling = path
        prevSibling[prevSibling.count - 1] = last - 1
        blocks.update(at: prevSibling) {
            $0.children.append(moved)
            $0.collapsed = false
        }
        return true
    }

    /// Shift+Tab: block becomes the sibling right after its parent, adopting any
    /// siblings that followed it as its own children (Logseq behavior). Without
    /// adopting them the block would jump *below* those trailing siblings instead
    /// of staying put visually.
    @discardableResult
    public static func outdent(_ path: [Int], in blocks: inout [Block]) -> Bool {
        guard let last = path.last, path.count >= 2 else { return false }
        let parentPath = Array(path.dropLast())
        let siblingCount = blocks.block(at: parentPath)?.children.count ?? 0
        guard last < siblingCount else { return false }
        // Pull out the following siblings first (back-to-front keeps indices
        // valid) so they can be re-parented under the outdented block.
        var following: [Block] = []
        var i = siblingCount - 1
        while i > last {
            var sib = path
            sib[sib.count - 1] = i
            if let removed = blocks.remove(at: sib) { following.insert(removed, at: 0) }
            i -= 1
        }
        guard var moved = blocks.remove(at: path) else { return false }
        if !following.isEmpty {
            moved.children.append(contentsOf: following)
            moved.collapsed = false
        }
        moved.invalidateRaw(deep: true) // deep: also re-serializes adopted children
        var target = parentPath
        target[target.count - 1] += 1
        blocks.insert(moved, at: target)
        return true
    }

    /// Validates that `paths` are contiguous siblings, returning their common
    /// parent path and sorted child indices; nil otherwise (a gap, mixed
    /// parents, or an empty path). Shared by the multi-block indent/outdent.
    private static func contiguousRun(_ paths: [[Int]]) -> (parentPath: [Int], indices: [Int])? {
        guard let first = paths.first else { return nil }
        let parentPath = Array(first.dropLast())
        let indices = paths.compactMap(\.last).sorted()
        guard paths.count == indices.count,
              paths.allSatisfy({ Array($0.dropLast()) == parentPath }),
              indices.last! - indices.first! == indices.count - 1
        else { return nil }
        return (parentPath, indices)
    }

    /// Tab on a multi-block selection: makes a contiguous sibling run the
    /// children of the block immediately above it, in order, each keeping its
    /// subtree. No-op (false) unless the paths are contiguous siblings with a
    /// preceding sibling to tuck under.
    @discardableResult
    public static func indentRun(_ paths: [[Int]], in blocks: inout [Block]) -> Bool {
        guard let run = contiguousRun(paths), run.indices.first! > 0 else { return false }
        var moved: [Block] = []
        for index in run.indices.reversed() {  // back-to-front keeps indices valid
            guard let b = blocks.remove(at: run.parentPath + [index]) else { return false }
            moved.insert(b, at: 0)
        }
        let reparented = moved.map { b -> Block in var b = b; b.invalidateRaw(deep: true); return b }
        blocks.update(at: run.parentPath + [run.indices.first! - 1]) {
            $0.children.append(contentsOf: reparented)
            $0.collapsed = false
        }
        return true
    }

    /// Shift+Tab on a multi-block selection: lifts a contiguous sibling run to
    /// its parent's level, inserted right after the parent, order preserved.
    /// Unlike single-block `outdent`, the run does *not* adopt the parent's
    /// other children — they stay put (a plain group-lift). No-op at top level.
    @discardableResult
    public static func outdentRun(_ paths: [[Int]], in blocks: inout [Block]) -> Bool {
        guard let run = contiguousRun(paths), run.parentPath.count >= 1 else { return false }
        var moved: [Block] = []
        for index in run.indices.reversed() {
            guard let b = blocks.remove(at: run.parentPath + [index]) else { return false }
            moved.insert(b, at: 0)
        }
        var insertPath = run.parentPath
        insertPath[insertPath.count - 1] += 1  // right after the (former) parent
        for (offset, b) in moved.enumerated() {
            var b = b
            b.invalidateRaw(deep: true)
            var p = insertPath
            p[p.count - 1] += offset
            blocks.insert(b, at: p)
        }
        return true
    }

    /// Alt+↑/↓: moves a block (with subtree) among its siblings.
    @discardableResult
    public static func move(_ path: [Int], by delta: Int, in blocks: inout [Block]) -> Bool {
        guard let last = path.last else { return false }
        let target = last + delta
        guard target >= 0 else { return false }
        let parentPath = Array(path.dropLast())
        let siblingCount = parentPath.isEmpty
            ? blocks.count
            : (blocks.block(at: parentPath)?.children.count ?? 0)
        guard target < siblingCount else { return false }
        guard let moved = blocks.remove(at: path) else { return false }
        var dest = path
        dest[dest.count - 1] = target
        blocks.insert(moved, at: dest)
        return true
    }

    /// Alt+↑/↓ on a multi-block selection: moves a run of blocks (each with its
    /// subtree) among their siblings as one unit. The paths must be siblings and
    /// contiguous — anything else has no well-defined "move by one" and returns
    /// false without mutating.
    @discardableResult
    public static func moveRun(_ paths: [[Int]], by delta: Int, in blocks: inout [Block]) -> Bool {
        guard let first = paths.first else { return false }
        if paths.count == 1 { return move(first, by: delta, in: &blocks) }
        let parentPath = Array(first.dropLast())
        let indices = paths.compactMap(\.last).sorted()
        guard paths.allSatisfy({ Array($0.dropLast()) == parentPath }),
              indices.last! - indices.first! == indices.count - 1  // contiguous
        else { return false }
        // Bounds for the whole run, then step the blocks one at a time — from
        // the leading edge moving up, from the trailing edge moving down — so
        // each swap is with the (unselected) neighbor of the run.
        let siblingCount = parentPath.isEmpty
            ? blocks.count
            : (blocks.block(at: parentPath)?.children.count ?? 0)
        guard indices.first! + delta >= 0, indices.last! + delta < siblingCount else { return false }
        for index in (delta < 0 ? indices : indices.reversed()) {
            guard move(parentPath + [index], by: delta, in: &blocks) else { return false }
        }
        return true
    }

    /// Drag-and-drop: moves blocks (each with its subtree) to an arbitrary
    /// position, possibly under a new parent. `destination` is an insertion
    /// path — its last component is the index among the new parent's children,
    /// expressed against the tree *before* any removal (the op adjusts it).
    /// Unlike `moveRun`, the sources may be non-contiguous and span parents.
    /// A dragged descendant of a dragged block travels with its ancestor.
    /// Returns false (without mutating) when the destination lies inside a
    /// dragged subtree or either side doesn't resolve.
    @discardableResult
    public static func move(_ paths: [[Int]], to destination: [Int], in blocks: inout [Block]) -> Bool {
        guard !destination.isEmpty else { return false }
        // Top-most dragged paths only, in visual (lexicographic) order.
        var roots: [[Int]] = []
        for p in paths.sorted(by: precedes)
        where !roots.contains(where: { p.count > $0.count && Array(p.prefix($0.count)) == $0 }) {
            roots.append(p)
        }
        guard !roots.isEmpty, roots.allSatisfy({ blocks.block(at: $0) != nil }) else { return false }
        for r in roots where destination.count >= r.count
            && Array(destination.prefix(r.count)) == r { return false }
        let destParent = Array(destination.dropLast())
        guard destParent.isEmpty || blocks.block(at: destParent) != nil else { return false }

        // Remove bottom-up (descending order keeps the remaining source paths
        // valid), adjusting the destination for every removal that shifts it.
        var dest = destination
        var moved: [(depth: Int, block: Block)] = []
        for path in roots.reversed() {
            guard let block = blocks.remove(at: path) else { return false }
            moved.append((path.count, block))
            let level = path.count - 1
            if dest.count > level, Array(dest.prefix(level)) == Array(path.prefix(level)),
               dest[level] > path[level] {
                dest[level] -= 1
            }
        }
        // Clamp the insertion index (an end-of-list drop can overshoot once the
        // sources above it are removed).
        let siblingCount = dest.count == 1
            ? blocks.count
            : (blocks.block(at: Array(dest.dropLast()))?.children.count ?? 0)
        dest[dest.count - 1] = min(dest[dest.count - 1], siblingCount)
        for (depth, block) in moved.reversed() {  // back to visual order
            var b = block
            // A depth change re-indents the subtree, so exact source slices no
            // longer apply (§4.2) — drop them for canonical re-serialization.
            if depth != dest.count { b.invalidateRaw(deep: true) }
            blocks.insert(b, at: dest)
            dest[dest.count - 1] += 1
        }
        return true
    }

    /// Lexicographic path order — the visual (top-to-bottom) order of rows.
    private static func precedes(_ a: [Int], _ b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }

    /// Backspace at start of an empty block: delete it; returns the path-id of
    /// the block that should receive focus (previous visible row).
    @discardableResult
    public static func delete(_ path: [Int], in blocks: inout [Block]) -> Block? {
        blocks.remove(at: path)
    }

    /// Splits a block at a cursor offset (Enter mid-text): the remainder moves
    /// to a new sibling (children stay with the original). Returns new id.
    @discardableResult
    public static func split(
        _ path: [Int], at offset: Int, in blocks: inout [Block]
    ) -> UUID? {
        guard let block = blocks.block(at: path) else { return nil }
        let content = block.content
        let idx = content.index(
            content.startIndex,
            offsetBy: min(max(offset, 0), content.count)
        )
        let head = String(content[..<idx])
        let tail = String(content[idx...])
        // Enter at the very start of a non-empty block: insert a blank line
        // *above* and leave this block — its content and its whole subtree —
        // intact. Otherwise the block would be emptied and the rule below would
        // reparent it (and its children) under the new empty block. An empty
        // block (head and tail both empty) falls through to make a sibling
        // below, preserving "Enter on a blank line adds another below".
        if head.isEmpty, !tail.isEmpty {
            let new = Block(content: "")
            blocks.insert(new, at: path)
            return block.id // cursor stays at the start of the (unchanged) block
        }
        blocks.update(at: path) { $0.content = head }
        let new = Block(content: tail)
        if let b = blocks.block(at: path), !b.children.isEmpty, !b.collapsed {
            blocks.update(at: path) { $0.children.insert(new, at: 0) }
        } else {
            var sibling = path
            sibling[sibling.count - 1] += 1
            blocks.insert(new, at: sibling)
        }
        return new.id
    }

    /// Merges a block into the previous visible block (Backspace at start of a
    /// non-empty block). Returns (receiver id, cursor offset in receiver).
    public static func mergeWithPrevious(
        _ path: [Int], in blocks: inout [Block]
    ) -> (UUID, Int)? {
        let rows = visibleRows(in: blocks)
        guard let rowIndex = rows.firstIndex(where: { $0.path == path }),
              rowIndex > 0 else { return nil }
        let prev = rows[rowIndex - 1]
        guard let merging = blocks.block(at: path),
              merging.children.isEmpty else { return nil }
        let offset = prev.block.content.count
        _ = blocks.remove(at: path)
        // Path of prev may have shifted only if it came after — it can't,
        // it precedes `path` in document order.
        blocks.update(at: prev.path) { $0.content += merging.content }
        return (prev.block.id, offset)
    }

    // MARK: - Clipboard (SPEC §13)

    /// Markdown (with indentation) for a copied subtree.
    public static func copyMarkdown(_ block: Block) -> String {
        var out = ""
        func walk(_ b: Block, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let lines = b.content.isEmpty ? [""] : b.content.components(separatedBy: "\n")
            out += indent + "- " + lines[0] + "\n"
            for line in lines.dropFirst() {
                out += indent + "  " + line + "\n"
            }
            for child in b.children { walk(child, depth: depth + 1) }
        }
        walk(block, depth: 0)
        return out
    }

    /// Splits pasted multi-line Markdown into blocks: by list structure when
    /// bullet markers are present, else one block per non-empty line.
    public static func blocksFromPasted(_ text: String) -> [Block] {
        if text.contains("\n- ") || text.hasPrefix("- ") {
            var parsed = PageParser.parse(text)
            invalidateAll(&parsed.blocks)
            return parsed.blocks
        }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Block(content: $0) }
    }

    private static func invalidateAll(_ blocks: inout [Block]) {
        for i in blocks.indices {
            blocks[i].invalidateRaw(deep: true)
        }
    }
}
