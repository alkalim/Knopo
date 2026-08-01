import Foundation
import Testing
@testable import Knopo
@testable import KnopoCore

@Suite struct OnDeviceAITests {
    @Test func groundedAnswerRequiresValidSourceAndSupportingQuotation() {
        let source = SearchHit(
            blockID: UUID(), pageKey: "design", pageDisplayName: "Design",
            content: "The index is rebuildable.")
        let generated = [
            QuotedClaim(
                text: "The index is rebuildable.",
                citations: [QuotedCitation(sourceNumber: 1, quote: "index is rebuildable")]),
            QuotedClaim(text: "No citation.", citations: []),
            QuotedClaim(
                text: "Invented source.",
                citations: [QuotedCitation(sourceNumber: 9, quote: "index is rebuildable")]),
            QuotedClaim(
                text: "Invented evidence.",
                citations: [QuotedCitation(sourceNumber: 1, quote: "SQLite is mandatory")]),
        ]

        let answer = GroundedAnswer.validate(generated, sources: [source])
        #expect(answer.claims.count == 1)
        #expect(answer.claims.first?.text == "The index is rebuildable.")
        #expect(answer.claims.first?.citations.map(\.source.blockID) == [source.blockID])
    }

    @Test func groundedAnswerNormalizesQuoteCaseAndWhitespaceAndDeduplicates() {
        let source = SearchHit(
            blockID: UUID(), pageKey: "notes", pageDisplayName: "Notes",
            content: "A supporting\n  fact lives here.")
        let answer = GroundedAnswer.validate(
            [QuotedClaim(text: "A fact.", citations: [
                QuotedCitation(sourceNumber: 1, quote: "SUPPORTING FACT"),
                QuotedCitation(sourceNumber: 1, quote: "supporting   fact"),
            ])], sources: [source])

        #expect(answer.claims.count == 1)
        #expect(answer.claims.first?.citations.count == 1)
    }

    @Test func searchPlanKeepsOnlyFocusedPlannerOutput() throws {
        let plan = try #require(AskSearchPlan(
            topic: "  anomaly detection  ",
            intent: "discover noteworthy material",
            semanticQueries: ["anomaly detection", "outlier detection", "ANOMALY DETECTION"],
            lexicalPhrases: ["anomaly detection"],
            lexicalTerms: ["anomaly", "detection", "outlier", "anomaly"]))

        #expect(plan.topic == "anomaly detection")
        #expect(plan.semanticQueries == ["anomaly detection", "outlier detection"])
        #expect(plan.lexicalTerms == ["anomaly", "detection", "outlier"])
        #expect(!plan.semanticQueries.contains("Show me cool notes about anomaly detection"))
    }

    @Test func searchPlanRejectsMissingRetrievalChannels() {
        #expect(AskSearchPlan(
            topic: "index format", intent: "decision",
            semanticQueries: [], lexicalPhrases: [], lexicalTerms: []) == nil)
    }

    @Test func evidenceSelectionPrefersDifferentPagesAndRemovesDuplicateText() {
        func hit(_ page: String, _ content: String) -> SearchHit {
            SearchHit(
                blockID: UUID(), pageKey: page.lowercased(),
                pageDisplayName: page, content: content)
        }
        let ranked = [
            hit("A", "first"), hit("A", "second"), hit("A", "third"),
            hit("B", "third"), hit("B", "fourth"), hit("C", "fifth"),
        ]

        let selected = AskEvidenceSelector.select(ranked, limit: 4)
        #expect(selected.map(\.content) == ["first", "second", "fourth", "fifth"])
    }

    @Test func answerPromptHasAHardTotalBudgetForLargeGraphBlocks() throws {
        let sources = (0..<12).map { index in
            SearchHit(
                blockID: UUID(), pageKey: "page-\(index)",
                pageDisplayName: String(repeating: "Long page name ", count: 20),
                content: String(repeating: "large anomaly detection note ", count: 1_000))
        }

        let prepared = try #require(AskPromptBuilder.prepare(
            question: "What notes mention anomaly detection?", sources: sources))
        #expect(prepared.text.utf8.count <= AskPromptBuilder.normalPromptUTF8Bytes)
        #expect(prepared.sources.count <= AskPromptBuilder.maximumSources)
        #expect(!prepared.text.contains("SOURCE 9"))
    }

    @Test func answerPromptBudgetAlsoBoundsDenseMultibyteText() throws {
        let source = SearchHit(
            blockID: UUID(), pageKey: "dense", pageDisplayName: String(repeating: "頁", count: 500),
            content: String(repeating: "異常検知🧠", count: 2_000))

        let prepared = try #require(AskPromptBuilder.prepare(
            question: "異常検知の例", sources: [source],
            maximumUTF8Bytes: AskPromptBuilder.retryPromptUTF8Bytes))
        #expect(prepared.text.utf8.count <= AskPromptBuilder.retryPromptUTF8Bytes)
        #expect(prepared.text.contains("異常検知"))
    }

    @Test func oversizedQuestionsAreRejectedBeforeModelUse() {
        #expect(AskPromptBuilder.validatedQuestion("anomaly detection") != nil)
        #expect(AskPromptBuilder.validatedQuestion(
            String(repeating: "x", count: AskPromptBuilder.maximumQuestionUTF8Bytes + 1)) == nil)
    }

    @Test func languageFilterRejectsMixedUnsupportedSentencesOnStrictRetry() {
        #expect(AskTextLanguage.dominant(
            in: "Anomaly detection identifies unusual observations in a time series.") == .english)
        #expect(AskTextLanguage.isStrictlyCompatible(
            "Anomaly detection identifies unusual observations.", with: .english))
        #expect(!AskTextLanguage.isStrictlyCompatible(
            "Anomaly detection identifies unusual observations. Это русское предложение.",
            with: .english))
    }
}
