import SwiftUI

/// A single-turn, retrieval-grounded question surface. There is deliberately
/// no chat transcript or action/tool affordance.
struct AskPanel: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var nav: Navigator
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var availability: AskAvailability?
    @State private var answer: GroundedAnswer?
    @State private var errorMessage: String?
    @State private var asking = false
    @State private var answerTask: Task<Void, Never>?
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask Your Notes").font(.title2.weight(.semibold))
                    Text("Answers and retrieval stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            TextField("What did I decide about…?", text: $question)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
                .focused($questionFocused)
                .onSubmit(ask)
                .disabled(availability != .available || asking)

            if let availability, case .unavailable(let reason) = availability {
                Label(reason, systemImage: "apple.intelligence")
                    .font(.callout).foregroundStyle(.secondary)
            } else if availability == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Apple Intelligence…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if asking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading relevant notes…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.callout).foregroundStyle(.secondary)
            } else if let answer {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(answer.claims) { claim in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attributed(claim))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(Array(claim.citations.enumerated()), id: \.element.id) {
                                    index, citation in
                                    Button {
                                        nav.openURL(
                                            KnopoURL.block(citation.source.blockID),
                                            inSidebar: wantsSidebarClick())
                                        dismiss()
                                    } label: {
                                        Text("[\(index + 1)] \(citation.source.pageDisplayName): “\(citation.quote)”")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Go to supporting block")
                                }
                            }
                            .environment(\.openURL, OpenURLAction { url in
                                nav.openURL(url, inSidebar: wantsSidebarClick())
                                dismiss()
                                return .handled
                            })
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Spacer(minLength: 0)
            HStack {
                Text("Every displayed claim includes verified source text.")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Ask", action: ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAsk)
            }
        }
        .padding(20)
        .frame(width: 600)
        .frame(minHeight: 280)
        .task {
            availability = await app.askAvailability()
            if availability == .available { questionFocused = true }
        }
        .onDisappear {
            answerTask?.cancel()
            answerTask = nil
        }
    }

    private var canAsk: Bool {
        availability == .available
            && !asking
            && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        guard canAsk else { return }
        let submitted = question.trimmingCharacters(in: .whitespacesAndNewlines)
        answerTask?.cancel()
        asking = true
        answer = nil
        errorMessage = nil
        answerTask = Task { @MainActor in
            do {
                let result = try await app.answerNotesQuestion(submitted)
                guard !Task.isCancelled else { return }
                answer = result
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            asking = false
        }
    }

    private func attributed(_ claim: GroundedClaim) -> AttributedString {
        var result = AttributedString(claim.text)
        for (index, groundedCitation) in claim.citations.enumerated() {
            var marker = AttributedString(" [\(index + 1)]")
            marker.link = KnopoURL.block(groundedCitation.source.blockID)
            result += marker
        }
        return result
    }
}
