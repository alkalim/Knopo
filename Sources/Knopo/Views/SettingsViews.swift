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
                    title: "Default date format",
                    format: preferences.defaultDateFormat,
                    explanation: "Copied to a new graph. Existing graphs keep their own format."
                ) { format in
                    preferences.defaultDateFormat = format
                    return true
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
                journalDateFormat: .default,
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
                    Section("Journals") {
                        JournalDateFormatControl(
                            title: "Date format",
                            format: app.journalDateFormat,
                            explanation: "Used to display journal titles in \(graphName). Markdown filenames and links always use the canonical format and remain unchanged."
                        ) { format in
                            do {
                                try app.updateJournalDateFormat(format)
                                return true
                            } catch {
                                errorMessage = error.localizedDescription
                                return false
                            }
                        }
                    }

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
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var formattedCacheSize: String {
        cacheSize.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "Unavailable"
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

/// Presets plus a validated custom Unicode pattern. `onChange` returns false
/// when persistence failed, in which case the control restores its prior value.
private struct JournalDateFormatControl: View {
    private static let customTag = "__custom__"

    let title: String
    let format: JournalDateFormat
    let explanation: String
    let onChange: (JournalDateFormat) -> Bool

    @State private var selection: String
    @State private var customDraft: String
    @State private var lastApplied: JournalDateFormat?
    @FocusState private var customFocused: Bool

    init(
        title: String,
        format: JournalDateFormat,
        explanation: String,
        onChange: @escaping (JournalDateFormat) -> Bool
    ) {
        self.title = title
        self.format = format
        self.explanation = explanation
        self.onChange = onChange
        let isPreset = JournalDateFormat.presets.contains(format)
        _selection = State(initialValue: isPreset ? format.pattern : Self.customTag)
        _customDraft = State(initialValue: format.pattern)
    }

    var body: some View {
        let sample = JournalDate.today()
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: $selection) {
                ForEach(JournalDateFormat.presets, id: \.self) { preset in
                    Text(preset.string(from: sample)).tag(preset.pattern)
                }
                Divider()
                Text("Custom…").tag(Self.customTag)
            }
            .onChange(of: selection) { _, value in
                guard value != Self.customTag else {
                    customDraft = format.pattern
                    return
                }
                customFocused = false
                applyValid(JournalDateFormat(pattern: value))
            }
            .onChange(of: format) { _, value in
                if lastApplied == value {
                    lastApplied = nil
                    return
                }
                lastApplied = nil
                selection = JournalDateFormat.presets.contains(value)
                    ? value.pattern : Self.customTag
                customDraft = value.pattern
            }

            if selection == Self.customTag {
                let candidate = JournalDateFormat(pattern: customDraft)
                let validationError = candidate.validationError
                TextField("Unicode date pattern", text: $customDraft)
                    .focused($customFocused)
                    .onSubmit(commitCustomDraft)
                    .onChange(of: customFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { commitCustomDraft() }
                    }
                if let error = validationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Example: \(candidate.string(from: sample))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Uses Unicode date patterns. Add {ordinal} immediately after d for English st/nd/rd/th.")
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
        let candidate = JournalDateFormat(pattern: customDraft)
        guard candidate.validationError == nil else { return }
        applyValid(candidate)
    }

    private func applyValid(_ candidate: JournalDateFormat) {
        lastApplied = candidate
        guard onChange(candidate) else {
            lastApplied = nil
            selection = JournalDateFormat.presets.contains(format)
                ? format.pattern : Self.customTag
            customDraft = format.pattern
            return
        }
    }
}
