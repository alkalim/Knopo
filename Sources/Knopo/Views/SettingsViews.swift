import SwiftUI
import KnopoCore

private enum SettingsLayout {
    static let width: CGFloat = 520
    static let height: CGFloat = 430
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $preferences.theme) {
                    ForEach(Preferences.Theme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Body font weight", selection: $preferences.contentWeight) {
                    ForEach(BlockRenderer.ContentWeight.allCases, id: \.self) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show brackets around page links",
                       isOn: $preferences.showPageRefBrackets)

                appearancePreview
            }

            Section("Journals") {
                JournalDateFormatControl(
                    title: "Date format",
                    format: preferences.defaultDateFormat,
                    explanation: "How journal titles are displayed, in every graph. Markdown filenames and links always use the canonical format and remain unchanged."
                ) { format in
                    preferences.defaultDateFormat = format
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .navigationTitle("Settings")
    }

    private var appearancePreview: some View {
        let rendered = BlockRenderer.render(
            content: "A [[linked page]] with **bold text** and #notes",
            context: BlockRenderer.Context(
                tables: false))
        return Text(AttributedString(rendered))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor))))
            .environment(\.openURL, OpenURLAction { _ in .handled })
            .accessibilityLabel("Appearance preview")
    }
}

struct GraphSettingsView: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cacheSize: Int64?
    @State private var rebuilding = false
    @State private var errorMessage: String?

    private var graphName: String { app.store.root.lastPathComponent }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Graph Settings — \(graphName)")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                }
                .padding(.horizontal, 50)
                .frame(height: 51)

                Divider()

                Form {
                    Section("Search Index") {
                        LabeledContent("Index size", value: formattedCacheSize)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button(rebuilding ? "Rebuilding…" : "Rebuild Index") {
                                    Task { await rebuildIndex() }
                                }
                                .disabled(rebuilding)
                                if rebuilding { ProgressView().controlSize(.small) }
                                Spacer()
                            }
                            Text("The index is rebuilt from the Markdown files. Recent pages are preserved.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
        .onAppear(perform: refreshCacheSize)
        .alert("Graph Settings Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            // `??` yields a String, so this takes Text's verbatim overload and
            // the fallback has to be localized here.
            Text(errorMessage ?? L("Unknown error"))
        }
    }

    private var formattedCacheSize: String {
        cacheSize.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? L("Unavailable")
    }

    private func refreshCacheSize() {
        cacheSize = app.store.indexMaintenance.sizeOnDisk()
    }

    private func rebuildIndex() async {
        rebuilding = true
        defer {
            rebuilding = false
            refreshCacheSize()
        }
        do {
            try await app.rebuildIndex()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Presets plus a validated custom Unicode pattern.
private struct JournalDateFormatControl: View {
    private static let customTag = "__custom__"
    /// Prefilled when switching to Custom from a built-in style, so the field
    /// starts from something valid rather than empty.
    private static let customSeed = "MMM d{ordinal}, yyyy"

    let title: LocalizedStringKey
    let format: JournalDateFormat
    let explanation: LocalizedStringKey
    let onChange: (JournalDateFormat) -> Void

    @State private var selection: String
    @State private var customDraft: String
    @State private var lastApplied: JournalDateFormat?
    @FocusState private var customFocused: Bool

    init(
        title: LocalizedStringKey,
        format: JournalDateFormat,
        explanation: LocalizedStringKey,
        onChange: @escaping (JournalDateFormat) -> Void
    ) {
        self.title = title
        self.format = format
        self.explanation = explanation
        self.onChange = onChange
        let isPreset = JournalDateFormat.presets.contains(format)
        _selection = State(initialValue: isPreset ? format.rawValue : Self.customTag)
        _customDraft = State(initialValue: format.customPattern ?? Self.customSeed)
    }

    var body: some View {
        let sample = JournalDate.today()
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: $selection) {
                ForEach(JournalDateFormat.presets, id: \.self) { preset in
                    Text(verbatim: Self.label(for: preset, on: sample)).tag(preset.rawValue)
                }
                Divider()
                Text("Custom…").tag(Self.customTag)
            }
            .onChange(of: selection) { _, value in
                guard value != Self.customTag else {
                    customDraft = format.customPattern ?? Self.customSeed
                    return
                }
                customFocused = false
                applyValid(JournalDateFormat(rawValue: value))
            }
            .onChange(of: format) { _, value in
                if lastApplied == value {
                    lastApplied = nil
                    return
                }
                lastApplied = nil
                selection = JournalDateFormat.presets.contains(value)
                    ? value.rawValue : Self.customTag
                customDraft = value.customPattern ?? Self.customSeed
            }

            if selection == Self.customTag {
                let candidate = JournalDateFormat(rawValue: customDraft)
                let problem = JournalDateFormat.problem(withPattern: customDraft)
                TextField("Unicode date pattern", text: $customDraft)
                    .focused($customFocused)
                    .onSubmit(commitCustomDraft)
                    .onChange(of: customFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { commitCustomDraft() }
                    }
                if let problem {
                    Text(Self.message(for: problem)).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Example: \(candidate.string(from: sample))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Self.patternHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear(perform: commitCustomDraft)
    }

    private func commitCustomDraft() {
        guard selection == Self.customTag else { return }
        guard JournalDateFormat.problem(withPattern: customDraft) == nil else { return }
        applyValid(JournalDateFormat(rawValue: customDraft))
    }

    private func applyValid(_ candidate: JournalDateFormat) {
        lastApplied = candidate
        onChange(candidate)
    }

    /// The style's own name, ahead of today's date in that style. The name is
    /// load-bearing: two styles can render identically - German abbreviates June
    /// as "Juni" either way, and Japanese never differs - so the example alone
    /// would hide a choice that matters in other months.
    private static func label(for format: JournalDateFormat, on sample: JournalDate) -> String {
        let example = format.string(from: sample)
        guard let style = format.style else { return example }
        return "\(name(for: style)) - \(example)"
    }

    private static var patternHelp: String {
        String(
            localized: "Uses Unicode date patterns. Add {ordinal} immediately after d for an ordinal day, where the language has one.",
            comment: "Help under the custom journal date field. {ordinal} and d are literal syntax - do not translate them. The surrounding explanation should be translated")
    }

    private static func name(for style: JournalDateFormat.Style) -> String {
        switch style {
        case .abbreviated:
            return String(localized: "Abbreviated",
                          comment: "Journal date format: shortened month name, Jun 10, 2026")
        case .long:
            return String(localized: "Long",
                          comment: "Journal date format: full month name, June 10, 2026")
        case .numeric:
            return String(localized: "Numeric",
                          comment: "Journal date format: digits only, 6/10/2026")
        case .iso:
            return String(localized: "ISO 8601",
                          comment: "Journal date format: 2026-06-10, the same form as the filename")
        }
    }

    /// KnopoCore names the problem; the wording lives here, so the engine needs
    /// no bundle of its own (workdocs/design/localization.md, 1e).
    ///
    /// `{ordinal}` and `d` are literal pattern syntax the validator matches on,
    /// so each comment says not to translate them.
    private static func message(for problem: JournalDateFormat.PatternProblem) -> String {
        switch problem {
        case .empty:
            return String(localized: "Enter a date format.",
                          comment: "Custom journal date pattern: the field is blank")
        case .reservedName:
            return String(
                localized: "That name belongs to a built-in format.",
                comment: "Custom journal date pattern: it spells a built-in style's name")
        case .repeatedOrdinal:
            return String(
                localized: "Use {ordinal} at most once.",
                comment: "Custom journal date pattern. {ordinal} is literal syntax - do not translate it")
        case .unknownPlaceholder:
            return String(
                localized: "The only supported placeholder is {ordinal}.",
                comment: "Custom journal date pattern. {ordinal} is literal syntax - do not translate it")
        case .ordinalNotAfterDay:
            return String(
                localized: "Place {ordinal} immediately after d.",
                comment: "Custom journal date pattern. {ordinal} and d are literal syntax - do not translate them")
        case .unbalancedQuote:
            return String(
                localized: "Close the quoted literal in the date format.",
                comment: "Custom journal date pattern: an apostrophe was left open")
        case .producesNoText:
            return String(
                localized: "This date format produces no text.",
                comment: "Custom journal date pattern: valid syntax, but renders nothing")
        }
    }
}
