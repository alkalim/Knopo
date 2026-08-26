import SwiftUI
import KnopoCore

struct GeneralSettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        let _ = preferences.renderRevision
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
        .frame(width: 520, height: 430)
        .navigationTitle("Settings")
    }

    private var appearancePreview: some View {
        let rendered = BlockRenderer.render(
            content: "A [[linked page]] with **bold text** and #notes",
            context: BlockRenderer.Context(
                pageRefBrackets: preferences.showPageRefBrackets,
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

    @State private var cacheSize: Int64 = 0
    @State private var rebuilding = false
    @State private var errorMessage: String?

    private var graphName: String { app.store.root.lastPathComponent }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Graph Settings — \(graphName)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 520, height: 430)
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
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
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
                apply(JournalDateFormat(pattern: value))
            }
            .onChange(of: format) { _, value in
                selection = JournalDateFormat.presets.contains(value)
                    ? value.pattern : Self.customTag
                customDraft = value.pattern
            }

            if selection == Self.customTag {
                TextField("Unicode date pattern", text: $customDraft)
                    .onChange(of: customDraft) { _, value in
                        guard let valid = JournalDateFormat(validating: value) else { return }
                        apply(valid)
                    }
                if let error = JournalDateFormat(pattern: customDraft).validationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let valid = JournalDateFormat(validating: customDraft) {
                    Text("Example: \(valid.string(from: sample))")
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
    }

    private func apply(_ candidate: JournalDateFormat) {
        guard candidate.validationError == nil else { return }
        guard onChange(candidate) else {
            selection = JournalDateFormat.presets.contains(format)
                ? format.pattern : Self.customTag
            customDraft = format.pattern
            return
        }
    }
}
