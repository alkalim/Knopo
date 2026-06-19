import AppKit
import EverseqCore

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

        init(resolveBlockRef: @escaping (UUID) -> String? = { _ in nil },
             assetsDir: URL? = nil,
             inlineQuoteBar: Bool = true,
             pageDisplayTitle: ((String) -> String?)? = nil,
             pageRefBrackets: Bool = BlockRenderer.bracketsEnabled,
             resolveEmbed: @escaping (EmbedTarget) -> NSAttributedString? = { _ in nil },
             resolveQuery: @escaping (QueryExpr) -> NSAttributedString? = { _ in nil }) {
            self.resolveBlockRef = resolveBlockRef
            self.assetsDir = assetsDir
            self.inlineQuoteBar = inlineQuoteBar
            self.pageDisplayTitle = pageDisplayTitle
            self.pageRefBrackets = pageRefBrackets
            self.resolveEmbed = resolveEmbed
            self.resolveQuery = resolveQuery
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
    /// TODO/DONE checkbox glyphs render this much larger than the text.
    static let todoBoxScale: CGFloat = 1.33
    /// Negative baseline offset nudges the checkbox down to sit centered on
    /// the text line (the glyph otherwise rides high).
    static let todoBoxBaselineOffset: CGFloat = -1.5

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
        return NSFont.systemFont(ofSize: baseFontSize)
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
            let style = (value as? NSParagraphStyle)
                .flatMap { $0.mutableCopy() as? NSMutableParagraphStyle }
                ?? NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            if lineSpacing > 0 { style.lineSpacing = max(style.lineSpacing, lineSpacing) }
            string.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    static func render(content: String, context: Context) -> NSAttributedString {
        let body = renderBody(content: content, context: context)
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

    private static func renderBody(content: String, context: Context) -> NSAttributedString {
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
            return inline(text, baseFont: headingFont(level: level), context: context)
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
                    context: context
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
                let box = todo == .done ? "☑ " : "☐ "
                out.append(NSAttributedString(string: box, attributes: [
                    .font: NSFont.systemFont(ofSize: baseFontSize * todoBoxScale),
                    .baselineOffset: todoBoxBaselineOffset,
                    .foregroundColor: todo == .done
                        ? NSColor.secondaryLabelColor : NSColor.controlAccentColor,
                    .link: URL(string: "everseq://toggle-todo")!,
                ]))
            }
            let body = inline(
                text,
                baseFont: baseFont(),
                baseColor: todo == .done ? .secondaryLabelColor : .textColor,
                strikethrough: false,
                context: context
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
        context: Context
    ) -> NSAttributedString {
        let nodes = InlineParser.parse(text)
        let out = NSMutableAttributedString()
        appendNodes(nodes, to: out, font: baseFont, color: baseColor,
                    strike: strikethrough, highlight: false, context: context)
        return out
    }

    private static func appendNodes(
        _ nodes: [InlineNode],
        to out: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        strike: Bool,
        highlight: Bool,
        context: Context
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
                appendNodes(inner, to: out, font: withTrait(font, .bold), color: color,
                            strike: strike, highlight: highlight, context: context)
            case .italic(let inner):
                appendNodes(inner, to: out, font: withTrait(font, .italic), color: color,
                            strike: strike, highlight: highlight, context: context)
            case .strike(let inner):
                appendNodes(inner, to: out, font: font, color: color,
                            strike: true, highlight: highlight, context: context)
            case .highlight(let inner):
                appendNodes(inner, to: out, font: font, color: color,
                            strike: strike, highlight: true, context: context)
            case .code(let s):
                out.append(NSAttributedString(string: s, attributes: attrs([
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                    .backgroundColor: NSColor.quaternarySystemFill,
                ])))
            case .math(let s):
                // SwiftMath may slip from v1 (SPEC §15); render source styled.
                out.append(NSAttributedString(string: s, attributes: attrs([
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
                    .foregroundColor: NSColor.systemTeal,
                ])))
            case .link(let label, let url):
                let dest = URL(string: url) ?? EverseqURL.page(url)
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
            case .image(let alt, let src):
                appendImage(alt: alt, src: src, attrs: attrs(), to: out, context: context)
            case .pageRef(let name):
                // Display the page's title while the link target keeps the
                // literal (stable) name: a date reference like `2026-06-10`
                // shows as "Jun 10th, 2026" but stays ISO in the file.
                let display = pageRefDisplay(name, context: context)
                let link = EverseqURL.page(name)
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
                        .link: EverseqURL.block(id),
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
                    .link: EverseqURL.tag(name),
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
                    case .block(let id): label = "⧉ embedded block"; link = EverseqURL.block(id)
                    case .page(let name): label = "⧉ \(name)"; link = EverseqURL.page(name)
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
        alt: String, src: String,
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
            let maxWidth: CGFloat = 420
            let size = image.size
            let scale = size.width > maxWidth ? maxWidth / size.width : 1
            attachment.bounds = CGRect(
                x: 0, y: 0, width: size.width * scale, height: size.height * scale
            )
            out.append(NSAttributedString(attachment: attachment))
        } else {
            var linkAttrs = attrs
            linkAttrs[.foregroundColor] = NSColor.linkColor
            if let url { linkAttrs[.link] = url }
            out.append(NSAttributedString(string: "🖼 \(alt.isEmpty ? src : alt)", attributes: linkAttrs))
        }
    }

    // MARK: - Fonts

    static func baseFont(italic: Bool = false) -> NSFont {
        let font = NSFont.systemFont(ofSize: baseFontSize)
        return italic ? withTrait(font, .italic) : font
    }

    static func withTrait(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(trait)
        )
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
