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
        /// Whether to draw faint `[[ ]]` around page references. Defaults to
        /// the user's stored preference so every render site honours it.
        var pageRefBrackets: Bool = BlockRenderer.bracketsEnabled
        /// Renders a `{{embed …}}` target's subtree (read-only); nil = broken
        /// embed (rendered literally). §7.6.
        var resolveEmbed: (EmbedTarget) -> NSAttributedString?
        /// Renders a `{{query …}}` expression's results (read-only); nil = no
        /// resolver in this context (rendered as a muted chip). §17.
        var resolveQuery: (QueryExpr) -> NSAttributedString?
        /// The block being rendered, when known — its TODO checkbox then carries
        /// a `knopo://toggle-todo?block=<id>` link so a click can toggle the
        /// right block even in a query result or embed (where the surrounding
        /// row/region navigates elsewhere). Nil → the bare `knopo://toggle-todo`.
        var todoBlockID: UUID?

        init(resolveBlockRef: @escaping (UUID) -> String? = { _ in nil },
             assetsDir: URL? = nil,
             inlineQuoteBar: Bool = true,
             pageDisplayTitle: ((String) -> String?)? = nil,
             pageRefBrackets: Bool = BlockRenderer.bracketsEnabled,
             resolveEmbed: @escaping (EmbedTarget) -> NSAttributedString? = { _ in nil },
             resolveQuery: @escaping (QueryExpr) -> NSAttributedString? = { _ in nil },
             todoBlockID: UUID? = nil) {
            self.resolveBlockRef = resolveBlockRef
            self.assetsDir = assetsDir
            self.inlineQuoteBar = inlineQuoteBar
            self.pageDisplayTitle = pageDisplayTitle
            self.pageRefBrackets = pageRefBrackets
            self.resolveEmbed = resolveEmbed
            self.resolveQuery = resolveQuery
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

    /// User preference: show faint `[[ ]]` brackets around page references.
    /// Per-app (a viewing/aesthetic choice), not per-graph data.
    static let pageRefBracketsKey = "showPageRefBrackets"
    static var bracketsEnabled: Bool {
        UserDefaults.standard.bool(forKey: pageRefBracketsKey)
    }

    /// The text shown for a `[[name]]` reference: a date renders as its display
    /// title ("Jun 10th, 2026"), other pages use a `title::` override if the
    /// context supplies one, else the literal name. The link target is always
    /// the literal name (stable identity).
    static func pageRefDisplay(_ name: String, context: Context) -> String {
        if let date = JournalDate(pageName: name) { return date.displayName }
        return context.pageDisplayTitle?(name) ?? name
    }

    /// Indent applied to quote text when the bar is drawn by the row view.
    static let quoteTextIndent: CGFloat = 13

    /// Unzoomed base text size.
    static let baseSize: CGFloat = 14
    static let minZoom: CGFloat = 0.6
    static let maxZoom: CGFloat = 2.6
    private static let zoomKey = "contentZoom"
    /// Global content zoom (Cmd +/−/0), persisted per app. Scales the base font
    /// size — and thus everything derived from it (headings, code, TODO box,
    /// emoji, the editor) — across the main view and the right pane alike.
    static var zoom: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: zoomKey)
        return saved <= 0 ? 1 : min(max(saved, minZoom), maxZoom)
    }() {
        didSet { UserDefaults.standard.set(zoom, forKey: zoomKey) }
    }
    /// On-screen base text size (base × zoom). Everything sizes off this.
    static var baseFontSize: CGFloat { baseSize * zoom }

    /// Marks an inline `code` run so `RenderedTextView` can draw a padded,
    /// rounded pill behind it (an attributed `.backgroundColor` is a tight,
    /// square rect with no breathing room).
    static let inlineCodeKey = NSAttributedString.Key("knopoInlineCode")
    /// Ordinal of an image token within one top-level block render. Attached to
    /// the object-replacement character so the row view can rewrite its source.
    static let imageIndexKey = NSAttributedString.Key("knopoImageIndex")

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
    private static let densityKey = "contentDensity"
    /// Global text-density multiplier (View ▸ Increase/Decrease Line Spacing),
    /// persisted, in 10% steps. Scales vertical breathing room — the gap between
    /// wrapped lines *within* a block and the gap *between* blocks — without
    /// touching font size. 1.0 = default; higher = airier.
    static var density: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: densityKey)
        return saved <= 0 ? 1 : min(max(saved, minDensity), maxDensity)
    }() {
        didSet { UserDefaults.standard.set(density, forKey: densityKey) }
    }
    /// Body-text font weight (View ▸ Font Weight). "Medium" is the app's
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

        var title: String {
            switch self {
            case .light: return "Light"
            case .medium: return "Medium"
            case .heavy: return "Heavy"
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
    }() {
        didSet { UserDefaults.standard.set(contentWeight.rawValue, forKey: contentWeightKey) }
    }

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
        _ string: NSMutableAttributedString, _ lineHeight: CGFloat, lineSpacing: CGFloat = 0
    ) {
        let full = NSRange(location: 0, length: string.length)
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
        pinLineHeight(mutable, lineHeight(forSource: content), lineSpacing: lineSpacing)
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
        let kind = BlockKind.classify(content)
        switch kind {
        case .horizontalRule:
            return NSAttributedString(
                string: "────────────",
                attributes: [.foregroundColor: NSColor.separatorColor,
                             .font: baseFont()]
            )
        case .fence(let language, let code):
            let out = NSMutableAttributedString()
            if !language.isEmpty {
                out.append(NSAttributedString(string: language + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 3, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            // No per-glyph background — the row cell draws one full-width box
            // (CodeBackgroundView) so there are no gaps between lines.
            out.append(NSAttributedString(string: code, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: baseFontSize - 1, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]))
            return out
        case .heading(let level, let text):
            return inline(text, baseFont: headingFont(level: level), context: context,
                          imageIndex: &imageIndex)
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
                context: context,
                imageIndex: &imageIndex
            )
            out.append(body)
            return out
        }
    }

    // MARK: - Inline rendering

    static func inline(
        _ text: String,
        baseFont: NSFont,
        baseColor: NSColor = .textColor,
        strikethrough: Bool = false,
        context: Context,
        imageIndex: inout Int
    ) -> NSAttributedString {
        let nodes = InlineParser.parse(text)
        let out = NSMutableAttributedString()
        appendNodes(nodes, to: out, font: baseFont, color: baseColor,
                    strike: strikethrough, highlight: false, context: context,
                    imageIndex: &imageIndex)
        return out
    }

    private static func appendNodes(
        _ nodes: [InlineNode],
        to out: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        strike: Bool,
        highlight: Bool,
        context: Context,
        imageIndex: inout Int
    ) {
        func attrs(_ extra: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if highlight { a[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35) }
            for (k, v) in extra { a[k] = v }
            return a
        }

        for node in nodes {
            switch node {
            case .text(let s):
                out.append(NSAttributedString(string: s, attributes: attrs()))
            case .lineBreak:
                out.append(NSAttributedString(string: "\n", attributes: attrs()))
            case .bold(let inner):
                appendNodes(inner, to: out, font: bolder(font), color: color,
                            strike: strike, highlight: highlight, context: context,
                            imageIndex: &imageIndex)
            case .italic(let inner):
                appendNodes(inner, to: out, font: withTrait(font, .italic), color: color,
                            strike: strike, highlight: highlight, context: context,
                            imageIndex: &imageIndex)
            case .strike(let inner):
                appendNodes(inner, to: out, font: font, color: color,
                            strike: true, highlight: highlight, context: context,
                            imageIndex: &imageIndex)
            case .highlight(let inner):
                appendNodes(inner, to: out, font: font, color: color,
                            strike: strike, highlight: true, context: context,
                            imageIndex: &imageIndex)
            case .code(let s):
                // Thin spaces give the pill *real* horizontal padding that takes
                // part in layout — painting the pill wider than the glyphs would
                // overlap tight neighbors and swallow source spaces. (They also
                // stand in for the dropped backticks in caret-index mapping.)
                // They keep the proportional font: in the mono font even a
                // "thin" space is a full fixed-width advance, far too wide.
                let pad = NSAttributedString(string: "\u{2009}", attributes: attrs([
                    inlineCodeKey: true,
                ]))
                out.append(pad)
                out.append(NSAttributedString(string: s, attributes: attrs([
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                    .foregroundColor: codeTextColor,
                    // No `.backgroundColor`: `RenderedTextView` draws a single
                    // rounded pill over the run (keyed on `inlineCodeKey`).
                    inlineCodeKey: true,
                ])))
                out.append(pad)
            case .math(let s):
                // SwiftMath may slip from v1 (SPEC §15); render source styled.
                out.append(NSAttributedString(string: s, attributes: attrs([
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                    .foregroundColor: NSColor.systemTeal,
                ])))
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
                out.append(NSAttributedString(string: "#\(name)", attributes: attrs([
                    .link: KnopoURL.tag(name),
                    .foregroundColor: BlockRenderer.tagColor,
                    .backgroundColor: BlockRenderer.tagBackground,
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
