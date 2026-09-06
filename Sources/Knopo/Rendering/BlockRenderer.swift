import AppKit
import CoreText
import KnopoCore

/// Renders a block's Markdown content as an NSAttributedString for unfocused
/// display (SPEC §5). Shared by the outline editor, reference lists, previews,
/// and the tag view.
enum BlockRenderer {

    struct Context {
        /// Resolves `((id))` to the referenced block's live content (§7.2);
        /// nil = broken reference (§7.3).
        var resolveBlockRef: (UUID) -> String?
        /// Whether a `[[name]]` target currently exists (stub refs render the
        /// same; kept for future styling).
        var assetsDir: URL?
        /// When true, quotes carry an inline bar character per line (for
        /// SwiftUI Text). The outline editor sets false and draws a single
        /// continuous bar at the row level instead; the renderer then only
        /// indents the quote text.
        var inlineQuoteBar = true
        /// Optional resolver for a non-date page's display title (a `title::`
        /// override). Returns nil to fall back to the literal name. Date pages
        /// are handled without this — their title is a pure function.
        var pageDisplayTitle: ((String) -> String?)?
        /// Journal-title format owned by the graph being rendered.
        var journalDateFormat: JournalDateFormat
        /// Whether to draw faint `[[ ]]` around page references. Defaults to
        /// the user's stored preference so every render site honours it.
        var pageRefBrackets: Bool = BlockRenderer.bracketsEnabled
        /// Renders a `{{embed …}}` target's subtree (read-only); nil = broken
        /// embed (rendered literally). §7.6.
        var resolveEmbed: (EmbedTarget) -> NSAttributedString?
        /// Renders a `{{query …}}` expression's results (read-only); nil = no
        /// resolver in this context (rendered as a muted chip). §17.
        var resolveQuery: (QueryExpr) -> NSAttributedString?
        /// Whether a table block renders as a laid-out table. False in the
        /// constrained contexts that show block content as a snippet — reference
        /// lists, previews, embed/query results, SwiftUI `Text` — where a grid
        /// has no room and nothing draws it; there the raw pipe source shows
        /// instead (SPEC §5.2).
        var tables = true
        /// Width available to this block's content, when the caller knows it (the
        /// outline row does; a SwiftUI `Text` doesn't). A table lays its columns
        /// out against this, so it always fits. Nil → columns take their natural
        /// widths, as if the row were unbounded.
        var contentWidth: CGFloat?
        /// The block's `table-width::` choice (SPEC §5.2). Only meaningful with
        /// `contentWidth` set — there's nothing to fill without a width.
        var tableWidth: TableWidth = .max
        /// The block being rendered, when known — its TODO checkbox then carries
        /// a `knopo://toggle-todo?block=<id>` link so a click can toggle the
        /// right block even in a query result or embed (where the surrounding
        /// row/region navigates elsewhere). Nil → the bare `knopo://toggle-todo`.
        var todoBlockID: UUID?

        init(resolveBlockRef: @escaping (UUID) -> String? = { _ in nil },
             assetsDir: URL? = nil,
             inlineQuoteBar: Bool = true,
             pageDisplayTitle: ((String) -> String?)? = nil,
             journalDateFormat: JournalDateFormat,
             pageRefBrackets: Bool = BlockRenderer.bracketsEnabled,
             resolveEmbed: @escaping (EmbedTarget) -> NSAttributedString? = { _ in nil },
             resolveQuery: @escaping (QueryExpr) -> NSAttributedString? = { _ in nil },
             tables: Bool = true,
             contentWidth: CGFloat? = nil,
             tableWidth: TableWidth = .max,
             todoBlockID: UUID? = nil) {
            self.resolveBlockRef = resolveBlockRef
            self.assetsDir = assetsDir
            self.inlineQuoteBar = inlineQuoteBar
            self.pageDisplayTitle = pageDisplayTitle
            self.journalDateFormat = journalDateFormat
            self.pageRefBrackets = pageRefBrackets
            self.resolveEmbed = resolveEmbed
            self.resolveQuery = resolveQuery
            self.tables = tables
            self.contentWidth = contentWidth
            self.tableWidth = tableWidth
            self.todoBlockID = todoBlockID
        }
    }

    /// A two-way appearance-adaptive colour.
    static func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Tag colour: a muted "dusty violet" rather than vivid `systemPurple` —
    /// calmer but still clearly readable in both appearances.
    static let tagColor = dynamicColor(
        light: NSColor(srgbRed: 0.42, green: 0.36, blue: 0.64, alpha: 1),
        dark: NSColor(srgbRed: 0.72, green: 0.66, blue: 0.88, alpha: 1))
    /// The faint pill behind a tag — the same hue, low alpha (a touch stronger
    /// in the dark so it still registers).
    static let tagBackground = dynamicColor(
        light: NSColor(srgbRed: 0.42, green: 0.36, blue: 0.64, alpha: 0.10),
        dark: NSColor(srgbRed: 0.72, green: 0.66, blue: 0.88, alpha: 0.16))

    /// Shown in an empty block that is a page's only content (SPEC §5.4) — the
    /// app's single empty-state affordance, whether the block is focused or not.
    /// Computed: a stored `let` would freeze the string at first access.
    static var emptyBlockHint: String {
        String(localized: "Start typing, or / for commands",
               comment: "Placeholder in the only, empty block of a page")
    }

    /// Draws `hint` where the block's first glyph would go. Both the focused
    /// editor and the rendered row call this, so the hint doesn't shift or change
    /// weight when the block takes focus. Drawn, never inserted: hint text in a
    /// text storage would be saved, indexed, found by `⌘F`, and measured into the
    /// row height.
    static func drawEmptyHint(_ hint: String, in view: NSTextView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A hair of inset so the caret doesn't sit on the hint's first glyph.
        let x = view.textContainerOrigin.x + 2
        let width = max(0, view.bounds.width - x - 2)
        guard width > 0 else { return }
        let attributed = NSAttributedString(string: hint, attributes: [
            .font: baseFont(),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        var line = CTLineCreateWithAttributedString(attributed)
        // At maximum zoom in a narrow pane the hint is wider than the row; a
        // CTLine never wraps, so truncate rather than let it run off the edge.
        if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) {
            let ellipsis = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\u{2026}",
                                   attributes: attributed.attributes(at: 0, effectiveRange: nil)))
            if let truncated = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) {
                line = truncated
            }
        }
        context.saveGState()
        // Core Text draws bottom-up; the text view is flipped.
        context.textMatrix = .identity
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: view.bounds.height - baseline(in: view))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Where the block's first glyph sits, measured from a throwaway TextKit
    /// layout built exactly like a one-line block.
    ///
    /// Blocks pin their line height *below* the font's natural height
    /// (`lineHeightScale`), and `NSAttributedString.draw` places a clamped line's
    /// baseline its own way — differently again on macOS 15, where the hint drew
    /// visibly above the line it stands in for. So the baseline is measured from
    /// the app's own layout and the glyphs are drawn on it directly. Asking the
    /// empty view is no good (an empty document has no line fragment to report),
    /// hence the throwaway layout.
    private static func baseline(in view: NSTextView) -> CGFloat {
        view.textContainerOrigin.y + firstBaselineOffset()
    }

    /// Cached per font/zoom/weight — the measurement is cheap but runs on every
    /// draw of every empty row otherwise.
    private static var cachedBaseline: (key: String, offset: CGFloat)?

    /// Distance from a block's line-box top to its first baseline, as TextKit
    /// lays it out with the app's font and pinned line height.
    static func firstBaselineOffset() -> CGFloat {
        let key = "\(baseFontSize)|\(contentWeight.rawValue)|\(density)"
        if let cached = cachedBaseline, cached.key == key { return cached.offset }
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        let paragraph = NSMutableParagraphStyle()
        let height = lineHeight(forSource: "")
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        content.attributedString = NSAttributedString(
            string: " ", attributes: [.font: baseFont(), .paragraphStyle: paragraph])
        layout.ensureLayout(for: layout.documentRange)
        var offset = baseFont().ascender
        if let fragment = layout.textLayoutFragment(for: layout.documentRange.location),
           let line = fragment.textLineFragments.first {
            offset = fragment.layoutFragmentFrame.minY
                + line.typographicBounds.minY + line.glyphOrigin.y
        }
        cachedBaseline = (key, offset)
        return offset
    }

    /// The band behind a table's header row — barely-there, like the grid rules,
    /// so the table reads as structure and not as a filled box.
    static let tableHeaderFill = dynamicColor(
        light: NSColor(white: 0, alpha: 0.045),
        dark: NSColor(white: 1, alpha: 0.07))

    /// User preference: show faint `[[ ]]` brackets around page references.
    /// Per-app (a viewing/aesthetic choice), not per-graph data.
    static let pageRefBracketsKey = "showPageRefBrackets"
    static var bracketsEnabled = UserDefaults.standard.bool(forKey: pageRefBracketsKey)

    /// The text shown for a `[[name]]` reference: a date renders as its display
    /// title ("Jun 10th, 2026"), other pages use a `title::` override if the
    /// context supplies one, else the literal name. The link target is always
    /// the literal name (stable identity).
    static func pageRefDisplay(_ name: String, context: Context) -> String {
        if let date = JournalDate(pageName: name) {
            return date.displayName(using: context.journalDateFormat)
        }
        return context.pageDisplayTitle?(name) ?? name
    }

    /// Indent applied to quote text when the bar is drawn by the row view.
    static let quoteTextIndent: CGFloat = 13

    /// Unzoomed base text size.
    static let baseSize: CGFloat = 14
    static let minZoom: CGFloat = 0.6
    static let maxZoom: CGFloat = 2.6
    static let zoomKey = "contentZoom"
    /// Global content zoom (Cmd +/−/0), persisted per app. Scales the base font
    /// size — and thus everything derived from it (headings, code, TODO box,
    /// emoji, the editor) — across the main view and the right pane alike.
    static var zoom: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: zoomKey)
        return saved <= 0 ? 1 : min(max(saved, minZoom), maxZoom)
    }()
    /// Page-title size. The journal feed's day headings are page titles too — a
    /// day rendered in the feed and the same day opened on its own must not change
    /// size — so both take it from here.
    static var pageTitleFontSize: CGFloat { 24 * zoom }

    /// On-screen base text size (base × zoom). Everything sizes off this.
    static var baseFontSize: CGFloat { baseSize * zoom }

    /// Marks an inline `code` run so `RenderedTextView` can draw a padded,
    /// rounded pill behind it (an attributed `.backgroundColor` is a tight,
    /// square rect with no breathing room).
    static let inlineCodeKey = NSAttributedString.Key("knopoInlineCode")
    /// Marks a `#tag` run so `RenderedTextView` draws its pill the same way as
    /// inline code (clamped to the run's line height), instead of a
    /// `.backgroundColor` that fills the whole line fragment.
    static let tagKey = NSAttributedString.Key("knopoTag")
    /// Ordinal of an image token within one top-level block render. Attached to
    /// the object-replacement character so the row view can rewrite its source.
    static let imageIndexKey = NSAttributedString.Key("knopoImageIndex")
    /// Source offset (UTF-16, into the block's content) that a rendered run came
    /// from, so a click in rendered text can be mapped back to the source the
    /// editor shows. Absent where the mapping isn't tracked (fences, tables,
    /// quotes, generated regions), and the caller then falls back to clamping.
    static let sourceOffsetKey = NSAttributedString.Key("knopoSourceOffset")
    /// Marks a run whose rendered text *is* its source text, so an offset within
    /// the run carries over character for character. Runs without it map as a
    /// whole to their token's start (a page ref renders as its title, so an
    /// offset inside it means nothing in the source).
    static let sourceVerbatimKey = NSAttributedString.Key("knopoSourceVerbatim")
    /// Marks a rendered table's whole run and carries its column geometry, so
    /// `RenderedTextView` can draw the grid and header band (TextKit 2 has no
    /// `NSTextTable`, so the columns are tab stops and the rules are drawn).
    static let tableKey = NSAttributedString.Key("knopoTable")

    /// Where a rendered table's vertical grid lines sit, as x offsets from the
    /// text container's leading edge — `columns + 1` of them, outer borders
    /// included — and how many lines of the block are table rows. The row count
    /// bounds the drawing: a block can render more lines than its table (its
    /// visible `key:: value` property lines follow it), and those must not get
    /// grid rules. A class so it rides along as an attribute value.
    final class TableGeometry: NSObject {
        let columnEdges: [CGFloat]
        let rowCount: Int
        init(columnEdges: [CGFloat], rowCount: Int) {
            self.columnEdges = columnEdges
            self.rowCount = rowCount
        }
    }

    /// Horizontal breathing room between a cell's text and its column rules.
    static var tableCellPad: CGFloat { (10 * zoom).rounded() }
    /// Vertical breathing room above and below a row's text. Added as paragraph
    /// spacing rather than line height, so the row grows but a tag or inline-code
    /// pill inside a cell still hugs its text instead of filling the whole row.
    static var tableRowPad: CGFloat { (4 * zoom).rounded() }
    /// Slack added to every column so a hair of measurement drift between
    /// `size()` (which sizes the columns) and TextKit 2 (which lays the row out)
    /// can never push a cell past its own tab stop and scramble the row.
    static let tableColumnSlack: CGFloat = 2
    /// Widest a column may get from its *content* before its cells tail-truncate.
    /// Caps how much one long-text column can dominate the proportions; the
    /// table's real width comes from `TableWidth` and the row width.
    static var tableMaxColumnWidth: CGFloat { (baseFontSize * 22).rounded() }
    /// Narrowest a column's *content* may be squeezed to when a table has to
    /// fit — room for an ellipsis — so no column collapses into its rules.
    static var tableMinColumnWidth: CGFloat { baseFontSize }

    /// How wide a table lays itself out, from `table-width:: max | min` on the
    /// block (SPEC §5.2). Either way the table never exceeds the row — columns
    /// are scaled to fit rather than clipped at the edge.
    enum TableWidth: String, CaseIterable {
        /// As wide as the row allows: columns share the full content width in
        /// proportion to their natural widths. The default.
        case max
        /// Only as wide as the content needs — but still scaled down if that
        /// would overflow the row.
        case min

        static let propertyKey = "table-width"

        /// Lenient parse of a hand-typed property value; an unrecognized value
        /// falls back to the default rather than mangling the table.
        init(propertyValue: String) {
            self = TableWidth(
                rawValue: propertyValue.trimmingCharacters(in: .whitespaces).lowercased()
            ) ?? .max
        }

    }

    /// Inline-code glyph color: a dark grey (not pure body-text black) so it
    /// reads as distinct on the code pill. Adapts to light/dark.
    static let codeTextColor: NSColor = NSColor(name: "knopoCode") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.78, alpha: 1)
            : NSColor(white: 0.30, alpha: 1)
    }

    /// Body-text color: a hair softer than the system `textColor` (pure black /
    /// pure white) so long outlines read less harshly, closer to the Logseq/Bear
    /// feel. Used by both the rendered rows and the focused editor so text
    /// doesn't shift on focus. Adapts to light/dark automatically.
    static let bodyColor: NSColor = NSColor(name: "knopoBody") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.88, alpha: 1)   // soft off-white on dark
            : NSColor(white: 0.17, alpha: 1)   // ~#2b2b2b on light
    }

    static let minDensity: CGFloat = 0.5
    static let maxDensity: CGFloat = 2.0
    static let densityKey = "contentDensity"
    /// Global text-density multiplier (View ▸ Increase/Decrease Line Spacing),
    /// persisted, in 10% steps. Scales vertical breathing room — the gap between
    /// wrapped lines *within* a block and the gap *between* blocks — without
    /// touching font size. 1.0 = default; higher = airier.
    static var density: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: densityKey)
        return saved <= 0 ? 1 : min(max(saved, minDensity), maxDensity)
    }()
    /// Body-text font weight (General Settings). "Medium" is the app's
    /// original weight (`.regular`); light/heavy step around it. A per-app
    /// aesthetic choice (not per-graph data), persisted. Applied to body text
    /// in both the rendered rows and the focused editor so weight never shifts
    /// on focus. Headings keep their own bold weight.
    enum ContentWeight: String, CaseIterable {
        case light, medium, heavy

        /// Value on the SF `wght` variation axis (≈ CSS weight numbers). We use
        /// the axis rather than `NSFont.Weight`, which snaps to nine discrete
        /// stops with nothing between Light (≈300) and Regular (400) — too
        /// coarse for the intermediate light/heavy steps we want.
        var wght: CGFloat {
            switch self {
            case .light: return 330    // ~10% above SF Light (≈300)
            case .medium: return 400   // Regular — the original default
            case .heavy: return 480    // clearly above medium, well below semibold (≈590)
            }
        }

        /// Separate literals on purpose - do not "simplify" into
        /// `rawValue.capitalized`, which is the persisted value.
        ///
        /// Its own table because "Light" is also an appearance theme, and the two
        /// want different words in most languages. The name must be a literal:
        /// `scripts/l10n-extract.sh` cannot see it through a constant.
        var title: String {
            switch self {
            case .light:
                return String(localized: "Light", table: "FontWeight", comment: "Body font weight")
            case .medium:
                return String(localized: "Medium", table: "FontWeight", comment: "Body font weight")
            case .heavy:
                return String(localized: "Heavy", table: "FontWeight", comment: "Body font weight")
            }
        }
    }

    /// UserDefaults key for the persisted weight. Exposed so the View menu can
    /// bind an `@AppStorage` to the same key — that makes its radio checkmark
    /// reactive (a menu-bar Picker/focused-value binding does not reliably
    /// re-render on change).
    static let contentWeightKey = "contentWeight"
    static var contentWeight: ContentWeight = {
        ContentWeight(rawValue: UserDefaults.standard.string(forKey: contentWeightKey) ?? "") ?? .medium
    }()

    /// SF `wght` OpenType variation axis identifier ('wght').
    private static let weightAxis = 0x77676874
    private static let variationKey =
        NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String)
    /// The system font at `size` and the current content weight. `.medium` is
    /// plain Regular (no variation); light/heavy ride the `wght` axis.
    static func weightedSystemFont(ofSize size: CGFloat) -> NSFont {
        applyingWeight(contentWeight.wght, to: NSFont.systemFont(ofSize: size),
                       skipIf: contentWeight == .medium)
    }

    /// Weight for **bold** runs: a fixed step above the body weight, so bold
    /// stays clearly bolder as the body weight rises (at heavy, plain `.bold`
    /// is barely above the body). Medium's 400 → 700 matches ordinary bold.
    static var boldWght: CGFloat { min(contentWeight.wght + 300, 900) }

    /// A bold rendition of `font` via the `wght` axis. The `.bold` *symbolic
    /// trait* is swallowed when the descriptor already pins an explicit `wght`
    /// (our light/heavy body text), so bold text wouldn't thicken; setting the
    /// axis directly does. Existing traits (italic) are preserved.
    static func bolder(_ font: NSFont) -> NSFont {
        applyingWeight(boldWght, to: font, skipIf: false)
    }

    private static func applyingWeight(
        _ wght: CGFloat, to font: NSFont, skipIf skip: Bool
    ) -> NSFont {
        guard !skip else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([
            variationKey: [weightAxis: wght],
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Line height is pinned to the font metrics times this factor — tightens
    /// vertical spacing without shrinking text.
    static let lineHeightScale: CGFloat = 0.9
    /// Extra gap between the *wrapped* lines within a block (not after the last
    /// line), so multi-line blocks breathe like Logseq. Single-line blocks are
    /// unaffected, so inter-block spacing stays compact. Scales with zoom and the
    /// text-density control.
    static var lineSpacing: CGFloat { 6 * zoom * density }
    /// Emoji render this much smaller than surrounding text.
    static let emojiScale: CGFloat = 0.9
    /// The TODO/DONE checkbox, drawn as a text attachment with exact bounds so
    /// it fits inside the pinned line box. The previous oversized `☐` glyph
    /// (1.33× the text font) had an ascent taller than the line: it pushed the
    /// first line's baseline down (misaligning the bullet), hung below the
    /// text band, and grew the row height past the pinned metrics.
    static func todoCheckbox(done: Bool, blockID: UUID? = nil) -> NSAttributedString {
        let font = baseFont()
        let side = (font.capHeight * 1.3).rounded()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let color: NSColor = done ? .secondaryLabelColor : .controlAccentColor
            let box = NSBezierPath(
                roundedRect: NSRect(x: 0.75, y: 0.75, width: side - 1.5, height: side - 1.5),
                xRadius: 2.5, yRadius: 2.5
            )
            box.lineWidth = 1.4
            color.setStroke()
            box.stroke()
            if done {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: side * 0.26, y: side * 0.52))
                check.line(to: NSPoint(x: side * 0.43, y: side * 0.32))
                check.line(to: NSPoint(x: side * 0.75, y: side * 0.70))
                check.lineWidth = 1.5
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            }
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centered on the cap-height band: bottom edge a hair under the
        // baseline, top well inside the font's ascent — the line keeps its
        // pinned height.
        attachment.bounds = CGRect(
            x: 0, y: ((font.capHeight - side) / 2).rounded(), width: side, height: side
        )
        let out = NSMutableAttributedString(attachment: attachment)
        out.append(NSAttributedString(string: " ", attributes: [.font: font]))
        // Carry the block id when known so a click in a query result / embed
        // toggles the right block, not whatever the surrounding row links to.
        let link = blockID.map { "knopo://toggle-todo?block=\($0.uuidString.lowercased())" }
            ?? "knopo://toggle-todo"
        out.addAttribute(
            .link, value: URL(string: link)!,
            range: NSRange(location: 0, length: out.length)
        )
        return out
    }

    /// Shared with the raw-source editor so heading rows keep their size when
    /// focused (no height "vibration" between edit and rendered modes).
    static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [26, 22, 19, 17, 15.5, 14.5]
        return NSFont.systemFont(ofSize: sizes[min(max(level, 1), 6) - 1] * zoom, weight: .bold)
    }

    /// The font whose metrics drive a block's line height — heading size for
    /// headings, base size otherwise. The editor and the rendered view must
    /// agree on this so focusing a block never changes its height (SPEC §5.4).
    static func pinnedFont(forSource source: String) -> NSFont {
        if case .heading(let level, _) = BlockKind.classify(source) {
            return headingFont(level: level)
        }
        return weightedSystemFont(ofSize: baseFontSize)
    }

    /// Fixed line height for a block's source. Pinning to the base font's
    /// metrics stops emoji (whose substituted font carries extra leading) from
    /// making a line taller in one render mode than the other.
    static func lineHeight(forSource source: String) -> CGFloat {
        (NSLayoutManager().defaultLineHeight(for: pinnedFont(forSource: source)) * lineHeightScale)
            .rounded()
    }

    /// Applies a fixed `lineHeight` across the string, preserving any existing
    /// paragraph style (e.g. quote indent).
    static func pinLineHeight(
        _ string: NSMutableAttributedString, _ lineHeight: CGFloat, lineSpacing: CGFloat = 0,
        range: NSRange? = nil
    ) {
        let full = range ?? NSRange(location: 0, length: string.length)
        guard full.length > 0 else { return }
        string.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            // Generated regions (embeds, query results) manage their own per-line
            // heights via `pinLineHeightPerParagraph` — a blanket base-height pin
            // here would flatten an embedded `## heading` and clip its top.
            if string.attribute(.embedRegion, at: range.location, effectiveRange: nil) != nil {
                return
            }
            let style = (value as? NSParagraphStyle)
                .flatMap { $0.mutableCopy() as? NSMutableParagraphStyle }
                ?? NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            if lineSpacing > 0 { style.lineSpacing = max(style.lineSpacing, lineSpacing) }
            string.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// Pins each line to a fixed height derived from the *tallest* font on that
    /// line. Unlike a single blanket pin, this keeps a heading line (or any
    /// larger-font line) at its full height instead of clipping it to the base
    /// metrics — used for generated regions (embeds, query results) that mix
    /// heading and body blocks.
    static func pinLineHeightPerParagraph(_ string: NSMutableAttributedString) {
        let ns = string.string as NSString
        var lineStart = 0
        while lineStart < ns.length {
            var start = lineStart, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
            let para = NSRange(location: start, length: end - start)
            var maxSize = baseFontSize
            string.enumerateAttribute(.font, in: para) { value, _, _ in
                if let f = value as? NSFont, f.pointSize > maxSize { maxSize = f.pointSize }
            }
            let height = (NSLayoutManager()
                .defaultLineHeight(for: .systemFont(ofSize: maxSize)) * lineHeightScale).rounded()
            string.enumerateAttribute(.paragraphStyle, in: para) { value, range, _ in
                let style = (value as? NSParagraphStyle)
                    .flatMap { $0.mutableCopy() as? NSMutableParagraphStyle }
                    ?? NSMutableParagraphStyle()
                style.minimumLineHeight = height
                style.maximumLineHeight = height
                string.addAttribute(.paragraphStyle, value: style, range: range)
            }
            lineStart = end
        }
    }

    static func render(content: String, context: Context) -> NSAttributedString {
        var imageIndex = 0
        let body = renderBody(content: content, context: context, imageIndex: &imageIndex)
        guard let mutable = body.mutableCopy() as? NSMutableAttributedString else { return body }
        shrinkEmoji(mutable, scale: emojiScale)
        // A table's "wrapped lines" are its rows: they must abut so the grid
        // reads as one figure, so it takes no inter-line spacing.
        let isTable = context.tables && BlockKind.classify(content).isTable
        pinLineHeight(mutable, lineHeight(forSource: content),
                      lineSpacing: isTable ? 0 : lineSpacing)
        return mutable
    }

    /// Scales emoji down relative to the surrounding text (emoji otherwise
    /// render visually larger than the text at the same point size). Shared with
    /// the focused editor so emoji are the same size focused and unfocused.
    static func shrinkEmoji(_ string: NSMutableAttributedString, scale: CGFloat) {
        let ns = string.string as NSString
        var edits: [(NSRange, NSFont)] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: .byComposedCharacterSequences
        ) { sub, range, _, _ in
            guard let sub,
                  sub.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
            else { return }
            let size = (string.attribute(.font, at: range.location, effectiveRange: nil)
                as? NSFont)?.pointSize ?? baseFontSize
            edits.append((range, NSFont.systemFont(ofSize: size * scale)))
        }
        for (range, font) in edits { string.addAttribute(.font, value: font, range: range) }
    }

    private static func renderBody(
        content: String, context: Context, imageIndex: inout Int
    ) -> NSAttributedString {
        var kind = BlockKind.classify(content)
        // Where a table can't be laid out or drawn (§5.2), it reads as its raw
        // pipe source — the honest snippet, not a half-rendered grid.
        if kind.isTable, !context.tables { kind = .paragraph(text: content, todo: nil) }
        switch kind {
        case .horizontalRule:
            return NSAttributedString(
                string: "────────────",
                attributes: [.foregroundColor: NSColor.separatorColor,
                             .font: baseFont()]
            )
        case .fence(let language, let code):
            let out = NSMutableAttributedString()
            // Both the language tag and the code are verbatim slices of the
            // source — the tag three characters past the opening fence, the code
            // one line further — so a click in either maps exactly.
            let firstLine = content.components(separatedBy: "\n").first ?? content
            let codeStart = (firstLine as NSString).length + 1
            if !language.isEmpty {
                out.append(NSAttributedString(string: language + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 3, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    sourceOffsetKey: 3,
                    sourceVerbatimKey: true,
                ]))
            }
            // No per-glyph background — the row cell draws one full-width box
            // (CodeBackgroundView) so there are no gaps between lines.
            out.append(NSAttributedString(string: code, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular),
                .foregroundColor: NSColor.textColor,
                sourceOffsetKey: codeStart,
                sourceVerbatimKey: true,
            ]))
            return out
        case .table(let header, let alignments, let rows):
            return renderTable(header: header, alignments: alignments, rows: rows,
                               context: context, imageIndex: &imageIndex)
        case .heading(let level, let text):
            return inline(text, baseFont: headingFont(level: level),
                          sourceBase: sourceBase(of: text, in: content),
                          context: context, imageIndex: &imageIndex)
        case .quote(let text):
            // Every line gets the quote bar; continuation lines may carry
            // their own `> ` marker (stripped) or none (Shift+Enter).
            // The bar is a narrow space with a background fill — backgrounds
            // cover the full line-fragment height, so adjacent lines connect
            // without the gaps a box-drawing glyph leaves.
            let bar = NSMutableAttributedString(string: "\u{2005}", attributes: [
                .backgroundColor: NSColor.tertiaryLabelColor,
                .font: baseFont(),
            ])
            bar.append(NSAttributedString(string: "\u{2002}", attributes: [.font: baseFont()]))
            let out = NSMutableAttributedString()
            for (i, rawLine) in text.components(separatedBy: "\n").enumerated() {
                var line = rawLine
                if i > 0 {
                    if line.hasPrefix("> ") { line.removeFirst(2) }
                    else if line == ">" { line = "" }
                    out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont()]))
                }
                if context.inlineQuoteBar { out.append(bar) }
                out.append(inline(
                    line,
                    baseFont: baseFont(italic: true),
                    baseColor: .secondaryLabelColor,
                    context: context,
                    imageIndex: &imageIndex
                ))
            }
            if !context.inlineQuoteBar {
                // The row view draws the bar; indent the text past it.
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = quoteTextIndent
                style.headIndent = quoteTextIndent
                out.addAttribute(
                    .paragraphStyle, value: style,
                    range: NSRange(location: 0, length: out.length)
                )
            }
            return out
        case .paragraph(let text, let todo):
            let out = NSMutableAttributedString()
            if let todo {
                out.append(todoCheckbox(done: todo == .done, blockID: context.todoBlockID))
            }
            let body = inline(
                text,
                baseFont: baseFont(),
                baseColor: todo == .done ? .secondaryLabelColor : bodyColor,
                strikethrough: false,
                sourceBase: sourceBase(of: text, in: content),
                context: context,
                imageIndex: &imageIndex
            )
            out.append(body)
            return out
        }
    }

    // MARK: - Tables (SPEC §5.2)

    /// Lays a GFM pipe table out as tab-stopped rows: cells render through the
    /// ordinary inline pipeline (refs, tags, emphasis all work), each column is
    /// as wide as its widest cell up to `tableMaxColumnWidth`, and every cell
    /// sits at its own left tab stop — computed per row from the cell's measured
    /// width, so left/center/right alignment is exact instead of relying on
    /// TextKit's center/right tab semantics. The grid itself is drawn by
    /// `RenderedTextView` from the `tableKey` geometry.
    ///
    /// v1 doesn't wrap inside a cell: a cell past the column cap tail-truncates
    /// with an ellipsis, and a table wider than the row is clipped, not reflowed.
    private static func renderTable(
        header: [String], alignments: [TableAlignment], rows: [[String]],
        context: Context, imageIndex: inout Int
    ) -> NSAttributedString {
        let columns = header.count
        guard columns > 0 else { return NSAttributedString() }
        // A cell is one line, so an `{{embed}}` / `{{query}}` in it renders as the
        // same muted chip every other constrained context shows. Expanding one
        // here would run the query and render every result row — a whole
        // multi-line region — only to truncate it to an ellipsis in a single-line
        // cell, on every render of the block.
        var cellContext = context
        cellContext.resolveEmbed = { _ in nil }
        cellContext.resolveQuery = { _ in nil }
        // Header first, then rows in source order — image indices must line up
        // with the source's image tokens for the row view's resize rewrite.
        var lines: [[NSAttributedString]] = [header.map {
            inline($0, baseFont: bolder(baseFont()), baseColor: bodyColor,
                   context: cellContext, imageIndex: &imageIndex)
        }]
        for row in rows {
            lines.append(row.map {
                inline($0, baseFont: baseFont(), baseColor: bodyColor,
                       context: cellContext, imageIndex: &imageIndex)
            })
        }
        // Natural column width: the widest cell, capped so one long-text column
        // can't dominate the proportions.
        var natural = [CGFloat](repeating: 0, count: columns)
        for line in lines {
            for (column, cell) in line.enumerated() where column < columns {
                natural[column] = max(natural[column],
                                      min(ceil(cell.size().width), tableMaxColumnWidth))
            }
        }
        let pad = tableCellPad(columns: columns, available: context.contentWidth)
        let laidOut = fittedColumnWidths(
            natural: natural, available: context.contentWidth,
            mode: context.tableWidth, pad: pad)
        let contentWidths = laidOut.map { max(0, $0 - pad * 2 - tableColumnSlack) }
        var edges: [CGFloat] = [0]
        for width in laidOut {
            edges.append(edges[edges.count - 1] + width)
        }

        let out = NSMutableAttributedString()
        let structure: [NSAttributedString.Key: Any] = [.font: baseFont()]
        for (index, line) in lines.enumerated() {
            let rowStart = out.length
            var stops: [NSTextTab] = []
            for column in 0..<columns {
                let cell = truncatedCell(line[column], toWidth: contentWidths[column])
                let cellWidth = min(ceil(cell.size().width), contentWidths[column])
                let free = contentWidths[column] - cellWidth
                let x: CGFloat
                switch alignments[column] {
                case .left: x = edges[column] + pad
                case .center: x = edges[column] + pad + (free / 2).rounded()
                case .right: x = edges[column] + pad + free
                }
                stops.append(NSTextTab(textAlignment: .left, location: x))
                // A tab before *every* cell (including the first) so one stop
                // per column positions it, whatever its alignment.
                out.append(NSAttributedString(string: "\t", attributes: structure))
                out.append(cell)
            }
            if index < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: structure))
            }
            let style = NSMutableParagraphStyle()
            style.tabStops = stops
            // A row is one line by construction; clipping keeps an over-wide
            // table from reflowing into a second line and breaking the grid.
            style.lineBreakMode = .byClipping
            // Breathing room inside the cell, split above and below the text so
            // it sits centred between the row's rules.
            style.paragraphSpacingBefore = tableRowPad
            style.paragraphSpacing = tableRowPad
            // The range covers the row's own newline too, so each paragraph —
            // terminator included — carries exactly one row's stops.
            out.addAttribute(.paragraphStyle, value: style,
                             range: NSRange(location: rowStart, length: out.length - rowStart))
        }
        out.addAttribute(tableKey,
                         value: TableGeometry(columnEdges: edges, rowCount: lines.count),
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// The per-cell padding a table with this many columns can afford. Padding
    /// and slack are a fixed cost per column that scaling can't recover, so a
    /// table with many columns in a narrow row trims its padding rather than
    /// overflowing — the one way "never clip" can hold for any column count.
    static func tableCellPad(columns: Int, available: CGFloat?) -> CGFloat {
        let standard = tableCellPad
        guard let available, available > 0, columns > 0 else { return standard }
        let affordable = (available / CGFloat(columns) - tableColumnSlack
            - tableMinColumnWidth) / 2
        return max(1, min(standard, affordable.rounded(.down)))
    }

    /// Turns natural content widths into the laid-out column widths (content plus
    /// padding), so a table always fits `available` — no clipping at the row edge.
    ///
    /// `.max` fills the width exactly, `.min` only shrinks when the natural
    /// widths would overflow. Growing scales every column alike, keeping the
    /// content's proportions. Shrinking instead caps the widest columns and leaves
    /// the rest alone, so the overflow comes out of the columns that have room to
    /// give — a `Qty` column keeps its heading rather than being squeezed to `Q…`
    /// to buy a few points for a paragraph-wide neighbour.
    static func fittedColumnWidths(
        natural: [CGFloat], available: CGFloat?, mode: TableWidth, pad: CGFloat
    ) -> [CGFloat] {
        let widths = natural.map { $0 + pad * 2 + tableColumnSlack }
        // No width to fit against: natural widths, as if the row were unbounded.
        guard let available, available > 0, !widths.isEmpty else { return widths }
        let total = widths.reduce(0, +)
        if total > available {
            let cap = widestColumnFitting(widths, available: available)
            return widths.map { min($0, cap) }
        }
        if mode == .max {
            let scale = available / total // ≥ 1 on this path
            return widths.map { $0 * scale }
        }
        return widths
    }

    /// The largest per-column cap whose clamped widths total `available` — the
    /// point at which the wide columns have absorbed the whole overflow and the
    /// narrow ones are still untouched. (Every column ends up at the cap only when
    /// even that isn't enough, i.e. an equal split.)
    private static func widestColumnFitting(
        _ widths: [CGFloat], available: CGFloat
    ) -> CGFloat {
        var remaining = available
        let ascending = widths.sorted()
        for (index, width) in ascending.enumerated() {
            let unresolved = CGFloat(ascending.count - index)
            // Can this column — and every wider one — keep its full width?
            if width * unresolved <= remaining {
                remaining -= width
            } else {
                return remaining / unresolved
            }
        }
        return ascending.last ?? 0
    }

    /// Tail-truncates a rendered cell that would overrun its column, keeping the
    /// cell's own styling and marking the cut with an ellipsis. Composed
    /// character sequences are dropped whole, so an emoji or accented letter
    /// never breaks apart mid-truncation.
    ///
    /// The cut point is binary-searched: measuring is by far the expensive part,
    /// and walking back one character at a time cost a full re-measure per
    /// character — seconds of hang on a cell holding a paragraph of text.
    private static func truncatedCell(
        _ cell: NSAttributedString, toWidth width: CGFloat
    ) -> NSAttributedString {
        guard ceil(cell.size().width) > width, cell.length > 0 else { return cell }
        let ellipsis = NSAttributedString(
            string: "…", attributes: cell.attributes(at: cell.length - 1, effectiveRange: nil))
        let ns = cell.string as NSString
        // Every composed-character boundary is a candidate cut, shortest first.
        var cuts = [0]
        var offset = 0
        while offset < ns.length {
            offset = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: offset))
            cuts.append(offset)
        }
        func truncated(at cut: Int) -> NSAttributedString {
            let out = NSMutableAttributedString(attributedString: cell.attributedSubstring(
                from: NSRange(location: 0, length: cut)))
            out.append(ellipsis)
            return out
        }
        // `cuts.last` is the whole cell, which the guard above proved too wide;
        // if even the bare ellipsis overflows there's nothing narrower to show.
        guard ceil(truncated(at: 0).size().width) <= width else { return ellipsis }
        var fitting = 0, tooWide = cuts.count - 1
        while tooWide - fitting > 1 {
            let middle = (fitting + tooWide) / 2
            if ceil(truncated(at: cuts[middle]).size().width) <= width {
                fitting = middle
            } else {
                tooWide = middle
            }
        }
        return truncated(at: cuts[fitting])
    }

    // MARK: - Inline rendering

    /// `sourceBase` is where `text` starts inside the block's content, so the
    /// runs can record real source offsets (§5.4). Nil where that mapping isn't
    /// tracked — a table cell or a quote line is lifted out of the content and
    /// a wrong offset would be worse than none.
    static func inline(
        _ text: String,
        baseFont: NSFont,
        baseColor: NSColor = .textColor,
        strikethrough: Bool = false,
        sourceBase: Int? = nil,
        context: Context,
        imageIndex: inout Int
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in InlineParser.parseSpans(text) {
            appendNode(span.node, to: out, font: baseFont, color: baseColor,
                       strike: strikethrough, highlight: false,
                       sourceOffset: sourceBase.map { $0 + span.range.location },
                       context: context, imageIndex: &imageIndex)
        }
        return out
    }

    /// The offset a block's inline `text` starts at within `content` — the length
    /// of whatever block marker was stripped (`## `, `TODO `, …).
    static func sourceBase(of text: String, in content: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let range = (content as NSString).range(of: text)
        return range.location == NSNotFound ? nil : range.location
    }

    /// Nested nodes (inside emphasis) share their parent's source offset: the
    /// parser reports ranges for top-level nodes only. A lone `.text` child gets
    /// the offset past the marker, which makes the common `**bold**` exact.
    private static func appendNodes(
        _ nodes: [InlineNode],
        to out: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        strike: Bool,
        highlight: Bool,
        sourceOffset: Int?,
        context: Context,
        imageIndex: inout Int
    ) {
        for node in nodes {
            appendNode(node, to: out, font: font, color: color, strike: strike,
                       highlight: highlight, sourceOffset: sourceOffset,
                       context: context, imageIndex: &imageIndex)
        }
    }

    /// Source offset for the contents of an emphasis run, i.e. past its marker.
    private static func insideMarker(_ offset: Int?, _ marker: Int) -> Int? {
        offset.map { $0 + marker }
    }

    /// Source offset of the closing delimiter after `text`, given the offset of
    /// the text itself — where a click on the pill's trailing padding belongs.
    private static func closingMarker(_ inner: Int?, after text: String) -> Int? {
        inner.map { $0 + (text as NSString).length }
    }

    /// Adds a source offset to `attributes` when there is one to add — an absent
    /// offset must leave the keys off entirely rather than storing an empty value.
    private static func marked(
        at offset: Int?, _ attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        guard let offset else { return attributes }
        var marked = attributes
        marked[sourceOffsetKey] = offset
        return marked
    }

    /// As `marked`, for a run whose rendered text is its source text.
    private static func verbatim(
        at offset: Int?, _ attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        guard let offset else { return attributes }
        var marked = marked(at: offset, attributes)
        marked[sourceVerbatimKey] = true
        return marked
    }

    private static func appendNode(
        _ node: InlineNode,
        to out: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        strike: Bool,
        highlight: Bool,
        sourceOffset: Int?,
        context: Context,
        imageIndex: inout Int
    ) {
        func attrs(_ extra: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let sourceOffset { a[sourceOffsetKey] = sourceOffset }
            if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if highlight { a[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35) }
            for (k, v) in extra { a[k] = v }
            return a
        }

        switch node {
            case .text(let s):
                // Rendered verbatim, so an offset inside this run maps 1:1.
                out.append(NSAttributedString(
                    string: s, attributes: attrs([sourceVerbatimKey: true])))
            case .lineBreak:
                out.append(NSAttributedString(string: "\n", attributes: attrs()))
            case .bold(let inner):
                appendNodes(inner, to: out, font: bolder(font), color: color,
                            strike: strike, highlight: highlight,
                            sourceOffset: insideMarker(sourceOffset, 2),
                            context: context, imageIndex: &imageIndex)
            case .italic(let inner):
                appendNodes(inner, to: out, font: withTrait(font, .italic), color: color,
                            strike: strike, highlight: highlight,
                            sourceOffset: insideMarker(sourceOffset, 1),
                            context: context, imageIndex: &imageIndex)
            case .strike(let inner):
                appendNodes(inner, to: out, font: font, color: color,
                            strike: true, highlight: highlight,
                            sourceOffset: insideMarker(sourceOffset, 2),
                            context: context, imageIndex: &imageIndex)
            case .highlight(let inner):
                appendNodes(inner, to: out, font: font, color: color,
                            strike: strike, highlight: true,
                            sourceOffset: insideMarker(sourceOffset, 2),
                            context: context, imageIndex: &imageIndex)
            case .code(let s):
                // Thin spaces give the pill *real* horizontal padding that takes
                // part in layout — painting the pill wider than the glyphs would
                // overlap tight neighbors and swallow source spaces. (They also
                // stand in for the dropped backticks in caret-index mapping.)
                // They keep the proportional font: in the mono font even a
                // "thin" space is a full fixed-width advance, far too wide.
                // The code text is its source text one delimiter in, so clicking
                // inside the pill maps character for character; the padding on
                // either side stands for the backticks and maps to them.
                let inner = insideMarker(sourceOffset, 1)
                out.append(NSAttributedString(string: "\u{2009}", attributes: attrs([
                    inlineCodeKey: true,
                ])))
                out.append(NSAttributedString(string: s, attributes: attrs(verbatim(
                    at: inner,
                    [.font: NSFont.monospacedSystemFont(
                        ofSize: font.pointSize - 1, weight: .regular),
                     .foregroundColor: codeTextColor,
                     // No `.backgroundColor`: `RenderedTextView` draws a single
                     // rounded pill over the run (keyed on `inlineCodeKey`).
                     inlineCodeKey: true]))))
                out.append(NSAttributedString(string: "\u{2009}", attributes: attrs(
                    marked(at: closingMarker(inner, after: s), [inlineCodeKey: true]))))
            case .math(let s):
                // SwiftMath may slip from v1 (SPEC §15); render source styled.
                out.append(NSAttributedString(string: s, attributes: attrs(verbatim(
                    at: insideMarker(sourceOffset, 1),
                    [.font: NSFont.monospacedSystemFont(
                        ofSize: font.pointSize - 1, weight: .regular),
                     .foregroundColor: NSColor.systemTeal]))))
            case .link(let label, let url):
                let dest = URL(string: url) ?? KnopoURL.page(url)
                // External link: underlined + a trailing ↗ marking that it
                // leaves the app — distinct from internal page refs.
                out.append(NSAttributedString(string: label, attributes: attrs([
                    .link: dest,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])))
                out.append(NSAttributedString(string: "\u{2009}\u{2197}", attributes: attrs([
                    .link: dest,
                    .foregroundColor: NSColor.linkColor,
                    .font: NSFont.systemFont(ofSize: font.pointSize - 2),
                ])))
            case .autolink(let url):
                // A bare URL: shown as itself, clickable, always external — no
                // `↗` (the URL is self-evidently a link) and never the internal
                // page fallback. `%`-encode so an unusual char can't nil the URL.
                let dest = URL(string: url)
                    ?? url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                        .flatMap(URL.init(string:))
                var linkAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
                if let dest { linkAttrs[.link] = dest }
                out.append(NSAttributedString(string: url, attributes: attrs(linkAttrs)))
            case .image(let alt, let src, let size):
                let index = imageIndex
                imageIndex += 1
                appendImage(alt: alt, src: src, size: size, imageIndex: index,
                            attrs: attrs(), to: out, context: context)
            case .pageRef(let name):
                // Display the page's title while the link target keeps the
                // literal (stable) name: a date reference like `2026-06-10`
                // shows as "Jun 10th, 2026" but stays ISO in the file.
                let display = pageRefDisplay(name, context: context)
                let link = KnopoURL.page(name)
                let nameAttrs = attrs([.link: link, .foregroundColor: NSColor.controlAccentColor])
                if context.pageRefBrackets {
                    // Optional Logseq-style faint brackets (aesthetic, §settings).
                    let bracketAttrs = attrs([.link: link,
                                              .foregroundColor: NSColor.tertiaryLabelColor])
                    out.append(NSAttributedString(string: "[[", attributes: bracketAttrs))
                    out.append(NSAttributedString(string: display, attributes: nameAttrs))
                    out.append(NSAttributedString(string: "]]", attributes: bracketAttrs))
                } else {
                    out.append(NSAttributedString(string: display, attributes: nameAttrs))
                }
            case .blockRef(let id):
                if let resolved = context.resolveBlockRef(id) {
                    // Transcluded live content, dotted underline (§7.2).
                    let firstLine = resolved.components(separatedBy: "\n").first ?? resolved
                    out.append(NSAttributedString(string: firstLine, attributes: attrs([
                        .link: KnopoURL.block(id),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                            | NSUnderlineStyle.patternDot.rawValue,
                        .underlineColor: NSColor.controlAccentColor,
                    ])))
                } else {
                    // Broken reference: render literally, never rewrite (§7.3).
                    out.append(NSAttributedString(
                        string: "((\(id.uuidString.lowercased())))",
                        attributes: attrs([
                            .foregroundColor: NSColor.systemRed,
                            .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 2, weight: .regular),
                        ])
                    ))
                }
            case .tag(let name):
                // No `.backgroundColor`: `RenderedTextView` draws the tag pill
                // (keyed on `tagKey`), clamped to the run's line height so a tall
                // inline image on the same line can't balloon it.
                out.append(NSAttributedString(string: "#\(name)", attributes: attrs([
                    .link: KnopoURL.tag(name),
                    .foregroundColor: BlockRenderer.tagColor,
                    BlockRenderer.tagKey: true,
                ])))
            case .embed(let target):
                // Read-only transclusion of a subtree/page (§7.6). The host
                // block stays editable; this is the rendered (unfocused) form.
                if let rendered = context.resolveEmbed(target) {
                    if out.length > 0 {
                        out.append(NSAttributedString(string: "\n", attributes: attrs()))
                    }
                    out.append(rendered)
                } else {
                    // No resolver in this context (e.g. a backlink list) or a
                    // missing target: show a compact, muted, clickable chip —
                    // not the raw `{{embed …}}` syntax.
                    let (label, link): (String, URL)
                    switch target {
                    case .block(let id): label = "⧉ embedded block"; link = KnopoURL.block(id)
                    case .page(let name): label = "⧉ \(name)"; link = KnopoURL.page(name)
                    }
                    out.append(NSAttributedString(string: label, attributes: attrs([
                        .link: link,
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])))
                }

            case .query(let expr):
                // Read-only query whose results render in place (§17). The host
                // block stays editable; this is the rendered (unfocused) form.
                if let rendered = context.resolveQuery(expr) {
                    if out.length > 0 {
                        out.append(NSAttributedString(string: "\n", attributes: attrs()))
                    }
                    out.append(rendered)
                } else {
                    // No resolver here (e.g. a backlink list) — a muted chip, not
                    // the raw `{{query …}}` syntax.
                    out.append(NSAttributedString(string: "⧉ query", attributes: attrs([
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])))
                }
        }
    }

    /// The literal `{{embed …}}` source, for a broken/unresolved embed.
    private static func embedLiteral(_ target: EmbedTarget) -> String {
        switch target {
        case .block(let id): return "{{embed ((\(id.uuidString.lowercased())))}}"
        case .page(let name): return "{{embed [[\(name)]]}}"
        }
    }

    private static func appendImage(
        alt: String, src: String, size explicitSize: ImageSize?, imageIndex: Int,
        attrs: [NSAttributedString.Key: Any],
        to out: NSMutableAttributedString,
        context: Context
    ) {
        // Relative paths resolve against <graph-root>/assets/ (SPEC §5.1).
        // `.standardized` collapses any `..` (Logseq writes `../assets/x.png`
        // from a page in pages/) so the file URL actually opens. The src is a
        // raw filesystem path, not percent-encoded, so build the URL from the
        // path rather than `URL(string:)` (which would choke on spaces/parens).
        let url: URL? = src.hasPrefix("http")
            ? URL(string: src)
            : context.assetsDir?.appendingPathComponent(src).standardized
        if let url, url.isFileURL, let image = NSImage(contentsOf: url) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let natural = NSSize(width: max(image.size.width, 1), height: max(image.size.height, 1))
            let boundsSize: NSSize
            switch (explicitSize?.width, explicitSize?.height) {
            case let (width?, height?):
                boundsSize = NSSize(width: max(CGFloat(width), 8),
                                    height: max(CGFloat(height), 8))
            case let (width?, nil):
                let targetWidth = max(CGFloat(width), 8)
                boundsSize = NSSize(width: targetWidth,
                                    height: max(targetWidth * natural.height / natural.width, 8))
            case let (nil, height?):
                let targetHeight = max(CGFloat(height), 8)
                boundsSize = NSSize(width: max(targetHeight * natural.width / natural.height, 8),
                                    height: targetHeight)
            case (nil, nil):
                let scale = natural.width > 420 ? 420 / natural.width : 1
                boundsSize = NSSize(width: natural.width * scale, height: natural.height * scale)
            }
            attachment.bounds = CGRect(origin: .zero, size: boundsSize)
            let rendered = NSMutableAttributedString(attachment: attachment)
            rendered.addAttribute(
                imageIndexKey, value: imageIndex,
                range: NSRange(location: 0, length: rendered.length)
            )
            out.append(rendered)
        } else {
            var linkAttrs = attrs
            linkAttrs[.foregroundColor] = NSColor.linkColor
            if let url { linkAttrs[.link] = url }
            out.append(NSAttributedString(string: "🖼 \(alt.isEmpty ? src : alt)", attributes: linkAttrs))
        }
    }

    // MARK: - Fonts

    static func baseFont(italic: Bool = false) -> NSFont {
        let font = weightedSystemFont(ofSize: baseFontSize)
        return italic ? withTrait(font, .italic) : font
    }

    static func withTrait(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        var descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(trait)
        )
        // `withSymbolicTraits` drops an explicit `wght`/optical-size variation,
        // so italic (or any trait) on light/heavy body text would snap back to
        // regular weight — re-apply the source font's variation to keep it.
        if let variation = font.fontDescriptor.fontAttributes[variationKey] {
            descriptor = descriptor.addingAttributes([variationKey: variation])
        }
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
