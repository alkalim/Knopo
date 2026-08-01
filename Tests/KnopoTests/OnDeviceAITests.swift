import Foundation
import Testing
@testable import Knopo
@testable import KnopoCore

@Suite struct OnDeviceAITests {
    @Test func groundedAnswerRequiresValidSourceAndSentenceNumbers() throws {
        let source = SearchHit(
            blockID: UUID(), pageKey: "design", pageDisplayName: "Design",
            content: "The index is rebuildable. The cache is derived.")
        let prompt = try #require(AskPromptBuilder.prepare(
            question: "How is the index stored?", sources: [source]))
        let generated = [
            SentenceReferencedClaim(
                text: "The index is rebuildable.",
                citations: [SentenceReference(sourceNumber: 1, sentenceNumber: 1)]),
            SentenceReferencedClaim(text: "No citation.", citations: []),
            SentenceReferencedClaim(
                text: "Invented source.",
                citations: [SentenceReference(sourceNumber: 9, sentenceNumber: 1)]),
            SentenceReferencedClaim(
                text: "Invented evidence.",
                citations: [SentenceReference(sourceNumber: 1, sentenceNumber: 9)]),
        ]

        let answer = GroundedAnswer.validate(generated, prompt: prompt)
        #expect(answer.claims.count == 1)
        #expect(answer.claims.first?.text == "The index is rebuildable.")
        #expect(answer.claims.first?.citations.map(\.source.blockID) == [source.blockID])
        #expect(answer.claims.first?.citations.first?.quote == "The index is rebuildable.")
    }

    @Test func groundedAnswerDeduplicatesRepeatedSentenceReferences() throws {
        let source = SearchHit(
            blockID: UUID(), pageKey: "notes", pageDisplayName: "Notes",
            content: "A supporting\n  fact lives here.")
        let prompt = try #require(AskPromptBuilder.prepare(
            question: "Where is the fact?", sources: [source]))
        let answer = GroundedAnswer.validate(
            [SentenceReferencedClaim(text: "A fact.", citations: [
                SentenceReference(sourceNumber: 1, sentenceNumber: 1),
                SentenceReference(sourceNumber: 1, sentenceNumber: 1),
            ])], prompt: prompt)

        #expect(answer.claims.count == 1)
        #expect(answer.claims.first?.citations.count == 1)
    }

    @Test func queryAnalysisRemovesConversationalAndSubjectiveFraming() throws {
        let plan = try #require(AskQueryAnalyzer.analyze(
            "Show me cool notes about anomaly detection"))
        #expect(plan.topic == "anomaly detection")
        #expect(plan.semanticQuery == "anomaly detection")
        #expect(plan.lexicalTerms == ["anomaly", "detection"])
        #expect(plan.responseMode == .retrievedNotes)
    }

    @Test func queryAnalysisKeepsDecisionIntentWithoutQuestionWords() throws {
        let aboutPlan = try #require(AskQueryAnalyzer.analyze(
            "What did I decide about the index format?"))
        #expect(aboutPlan.topic == "index format")
        #expect(aboutPlan.semanticQuery == "decision about index format")
        #expect(aboutPlan.lexicalTerms == ["index", "format"])
        #expect(aboutPlan.responseMode == .generatedAnswer)

        let reorderedPlan = try #require(AskQueryAnalyzer.analyze(
            "Which index format did I choose?"))
        #expect(reorderedPlan.topic == "index format")
        #expect(reorderedPlan.semanticQuery == "decision about index format")
    }

    @Test func queryAnalysisPreservesMeaningfulNegation() throws {
        let plan = try #require(AskQueryAnalyzer.analyze(
            "Why did we not choose SQLite?"))
        #expect(plan.topic == "not choose SQLite")
        #expect(plan.semanticQuery == "reasons for not choose SQLite")
        #expect(plan.lexicalTerms == ["choose", "SQLite"])
    }

    @Test func queryAnalysisDoesNotDiscardSubjectWordsThatAreAlsoAppVocabulary() throws {
        let plan = try #require(AskQueryAnalyzer.analyze("Find page cache behavior"))
        #expect(plan.topic == "page cache behavior")
        #expect(plan.lexicalTerms == ["page", "cache", "behavior"])
    }

    @Test func queryAnalysisDoesNotMistakeSubjectWordsForSearchCommands() throws {
        let crops = try #require(AskQueryAnalyzer.analyze("cover crops"))
        #expect(crops.topic == "cover crops")
        let references = try #require(AskQueryAnalyzer.analyze("reference counting"))
        #expect(references.topic == "reference counting")
        let impact = try #require(AskQueryAnalyzer.analyze("Show impact on latency"))
        #expect(impact.topic == "impact on latency")
    }

    @Test func queryAnalysisRecognizesExplicitNotesSearchFrames() throws {
        let plan = try #require(AskQueryAnalyzer.analyze(
            "Find notes on anomaly detection"))
        #expect(plan.topic == "anomaly detection")
        #expect(plan.responseMode == .retrievedNotes)
    }

    @Test func queryAnalysisRejectsQuestionsWithoutASearchableTopic() {
        #expect(AskQueryAnalyzer.analyze("show me notes") == nil)
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

    @Test func retrievedNotesAnswerReturnsSourcesWithoutGeneratedClaims() {
        let sources = [
            SearchHit(
                blockID: UUID(), pageKey: "research", pageDisplayName: "Research",
                content: "Outlier detection example"),
        ]
        let answer = GroundedAnswer.retrievedNotes(sources)
        #expect(answer.presentation == .retrievedNotes)
        #expect(answer.claims.map(\.text) == ["Outlier detection example"])
        #expect(answer.claims.first?.citations.first?.source.blockID == sources[0].blockID)
    }

    @Test func answerPromptNumbersSentencesAndKeepsTheirLocalMapping() throws {
        let source = SearchHit(
            blockID: UUID(), pageKey: "research", pageDisplayName: "Research",
            content: "First observation. Second observation.")
        let prepared = try #require(AskPromptBuilder.prepare(
            question: "What happened?", sources: [source]))
        #expect(prepared.text.contains("S1: First observation."))
        #expect(prepared.text.contains("S2: Second observation."))
        #expect(prepared.sentences == [["First observation.", "Second observation."]])
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
