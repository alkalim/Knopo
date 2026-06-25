import Foundation

/// A `key:: value` property line attached to a block.
public struct BlockProperty: Equatable, Hashable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Exact source bytes a block was parsed from, used for byte-stable round-tripping.
/// A block whose `raw` is intact (and whose depth hasn't changed) is re-emitted verbatim.
public struct RawSource: Equatable, Sendable {
    /// The block's own lines (bullet line + continuation lines), exactly as read,
    /// including line terminators. Does not include children.
    public var text: String
    /// Outline depth at parse time (0 = top level).
    public var depth: Int

    public init(text: String, depth: Int) {
        self.text = text
        self.depth = depth
    }
}

/// A single outline node: one Markdown paragraph plus its children. (SPEC §3.1)
public struct Block: Identifiable, Sendable {
    /// Stable for the block's lifetime, including across moves between pages.
    public let id: UUID
    /// Raw Markdown source, a single logical paragraph (may contain newlines for
    /// multi-line blocks: code fences, quotes). May be empty.
    public var content: String {
        didSet { if content != oldValue { raw = nil } }
    }
    public var children: [Block]
    /// Fold state; persisted as `collapsed:: true` only when true.
    public var collapsed: Bool {
        didSet { if collapsed != oldValue { raw = nil } }
    }
    /// Whether `id:: <uuid>` is written into the file. Set once the block is
    /// referenced; never cleared automatically. (SPEC §4.2)
    public var idPersisted: Bool {
        didSet { if idPersisted != oldValue { raw = nil } }
    }
    /// `key:: value` lines other than `id::` / `collapsed::`, in file order.
    public var properties: [BlockProperty] {
        didSet { if properties != oldValue { raw = nil } }
    }
    /// Exact source for byte-stable round-trip; nil when the block was created
    /// or edited in memory.
    public var raw: RawSource?

    public init(
        id: UUID = UUID(),
        content: String = "",
        children: [Block] = [],
        collapsed: Bool = false,
        idPersisted: Bool = false,
        properties: [BlockProperty] = [],
        raw: RawSource? = nil
    ) {
        self.id = id
        self.content = content
        self.children = children
        self.collapsed = collapsed
        self.idPersisted = idPersisted
        self.properties = properties
        self.raw = raw
    }

    /// Discards raw source for this block (and optionally the whole subtree),
    /// forcing canonical re-serialization. Needed when the block's depth changes.
    public mutating func invalidateRaw(deep: Bool = false) {
        raw = nil
        if deep {
            for i in children.indices { children[i].invalidateRaw(deep: true) }
        }
    }

    /// Depth-first traversal of this block and all descendants.
    public func forEachBlock(_ body: (Block) -> Void) {
        body(self)
        for child in children { child.forEachBlock(body) }
    }

    /// The `TODO ` / `DONE ` keyword state, if the content starts with one. (SPEC §5.2)
    public var todoState: TodoState? { TodoState(content: content) }

    // MARK: - Editable source (properties as first-class, editable text)

    /// Display/rendering properties that affect *how* a block looks but aren't
    /// shown as editable `key:: value` text — set via UI (e.g. the bullet menu),
    /// like Logseq's hidden built-in properties. They round-trip in the file but
    /// stay out of the editor and the rendered body.
    public static let hiddenPropertyKeys: Set<String> = ["background-color"]

    /// The block's raw body as shown in the focused editor: content lines
    /// followed by user `key:: value` property lines. The machine-managed
    /// `id::` / `collapsed::` and the hidden display properties above are
    /// deliberately omitted, so editing them isn't possible by accident.
    public var editableSource: String {
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        lines += properties
            .filter { !Self.hiddenPropertyKeys.contains($0.key) }
            .map { "\($0.key):: \($0.value)" }
        return lines.joined(separator: "\n")
    }

    /// Inverse of `editableSource`: re-splits edited text into content and user
    /// properties, preserving `id`/`collapsed` and the hidden display properties
    /// (none of which are shown in the editor).
    public mutating func setEditableSource(_ text: String) {
        let preserved = properties.filter { Self.hiddenPropertyKeys.contains($0.key) }
        var newContent: [String] = []
        var newProps: [BlockProperty] = []
        for line in text.components(separatedBy: "\n") {
            // `id`/`collapsed`/hidden keys aren't shown in the editor; if typed,
            // leave them as content rather than hijacking the managed properties.
            if let prop = PageParser.matchProperty(line),
               prop.key != "id", prop.key != "collapsed",
               !Self.hiddenPropertyKeys.contains(prop.key) {
                newProps.append(prop)
            } else {
                newContent.append(line)
            }
        }
        content = newContent.joined(separator: "\n")
        properties = newProps + preserved
    }
}

public enum TodoState: String, Sendable {
    case todo = "TODO"
    case done = "DONE"

    public init?(content: String) {
        if content.hasPrefix("TODO ") || content == "TODO" { self = .todo }
        else if content.hasPrefix("DONE ") || content == "DONE" { self = .done }
        else { return nil }
    }

    public var toggled: TodoState { self == .todo ? .done : .todo }
}

// MARK: - Tree helpers

extension Array where Element == Block {
    /// Finds the path (index at each level) to the block with the given id.
    public func path(to id: UUID) -> [Int]? {
        for (i, block) in enumerated() {
            if block.id == id { return [i] }
            if let sub = block.children.path(to: id) { return [i] + sub }
        }
        return nil
    }

    public func block(at path: [Int]) -> Block? {
        guard let first = path.first, indices.contains(first) else { return nil }
        let rest = Array<Int>(path.dropFirst())
        if rest.isEmpty { return self[first] }
        return self[first].children.block(at: rest)
    }

    public func block(id: UUID) -> Block? {
        guard let p = path(to: id) else { return nil }
        return block(at: p)
    }

    public mutating func update(at path: [Int], _ transform: (inout Block) -> Void) {
        guard let first = path.first, indices.contains(first) else { return }
        let rest = Array<Int>(path.dropFirst())
        if rest.isEmpty {
            transform(&self[first])
        } else {
            self[first].children.update(at: rest, transform)
        }
    }

    public mutating func remove(at path: [Int]) -> Block? {
        guard let first = path.first, indices.contains(first) else { return nil }
        let rest = Array<Int>(path.dropFirst())
        if rest.isEmpty { return remove(at: first) }
        var c = self[first].children
        let removed = c.remove(at: rest)
        self[first].children = c
        return removed
    }

    public mutating func insert(_ block: Block, at path: [Int]) {
        guard let first = path.first else { return }
        let rest = Array<Int>(path.dropFirst())
        if rest.isEmpty {
            let idx = Swift.min(Swift.max(first, 0), count)
            insert(block, at: idx)
        } else if indices.contains(first) {
            self[first].children.insert(block, at: rest)
        }
    }

    /// All blocks in the forest, depth-first.
    public var flattened: [Block] {
        var out: [Block] = []
        for b in self { b.forEachBlock { out.append($0) } }
        return out
    }
}
