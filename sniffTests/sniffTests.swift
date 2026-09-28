import Foundation
import Combine
import Testing
@testable import Sniff

@MainActor
struct sniffTests {

    // MARK: - Helpers

    private func makePipeline() -> AudioQuestionPipeline {
        AudioQuestionPipeline(questionDetectionService: QuestionDetectionService())
    }

    private func readiness(permissions: Bool, speechModel: Bool, credential: Bool) -> OnboardingReadiness {
        OnboardingReadiness(
            permissionsGranted: permissions,
            speechModelInstalled: speechModel,
            llmCredentialReady: credential
        )
    }

    /// Runs `body` against a buffer with a live session, then returns what it persisted.
    private func transcriptFileContents(_ body: (TranscriptBuffer) -> Void) throws -> String {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let buffer = TranscriptBuffer()
        buffer.startSession(saveDirectoryURL: tempDir)
        body(buffer)
        buffer.stopSession()

        let items = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(items.count == 1)
        return try String(contentsOf: tempDir.appendingPathComponent(items[0]), encoding: .utf8)
    }

    @Test func screenDetectionFindsQuestionsWithPunctuation() {
        let service = QuestionDetectionService()
        let text = "This is a statement. What is this? Another?"
        let results = service.detectQuestions(in: text)
        
        #expect(results.contains("What is this?"))
        #expect(results.contains("Another?"))
    }
    
    @Test func audioDetectionFindsQuestionsWithoutPunctuation() {
        let service = QuestionDetectionService()
        let text = "how does this work please explain the steps"
        let results = service.detectQuestions(in: text)
        
        #expect(results.contains { $0.lowercased().hasPrefix("how does this work") })
    }
    
    @Test func screenDetectionDedupes() {
        let service = QuestionDetectionService()
        let text = "What is this? what is this?"
        let results = service.detectQuestions(in: text)
        
        #expect(results.count == 1)
    }

    @Test func qaManagerNavigationAndUpdates() {
        let manager = QAManager()
        
        let first = manager.addQuestion("What is Sniff?", source: .manual)
        _ = manager.addQuestion("How does it work?", source: .manual)
        
        #expect(manager.currentIndex == 1)
        #expect(manager.currentItem?.question == "How does it work?")
        
        manager.goToPrevious()
        #expect(manager.currentItem?.id == first.id)
        
        manager.updateAnswer(for: first.id, answer: "An assistant.")
        #expect(manager.items.first?.answer == "An assistant.")
        
        manager.clear()
        #expect(manager.items.isEmpty)
        #expect(manager.currentIndex == -1)
    }

    @Test func transcriptBufferClearResetsState() {
        let buffer = TranscriptBuffer()
        buffer.commitPending(text: "Hello world.", speaker: .you)
        buffer.updateLatestQuestion("What is this?")
        #expect(!buffer.displayChunks.isEmpty)

        buffer.clear()
        #expect(buffer.displayChunks.isEmpty)
        #expect(buffer.latestQuestion == nil)
    }

    // MARK: - AudioQuestionPipeline Tests (Punctuation-based detection)
    
    @Test func pipelinePicksQuestionAmongSurroundingSentences() {
        let pipeline = makePipeline()
        
        let result = pipeline.process(recentText: "First sentence. What is this? Another statement!")
        
        #expect(result.latestQuestion == "What is this?")
        #expect(result.questions.count == 1)
    }
    
    @Test func pipelineDetectsMultipleQuestions() {
        let pipeline = makePipeline()
        
        let result = pipeline.process(recentText: "What is this? How does it work?")
        
        #expect(result.questions.count == 2)
        #expect(result.latestQuestion == "How does it work?")
    }
    
    @Test func pipelineHandlesEmptyInput() {
        let pipeline = makePipeline()
        
        let result = pipeline.process(recentText: "")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    @Test func pipelineIgnoresStatementEvenWithQuestionKeyword() {
        let pipeline = makePipeline()
        
        // "which" appears mid-sentence, but ends with period - not a question
        let result = pipeline.process(recentText: "JavaScript which is a language.")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    // MARK: - QuestionDetectionService Edge Cases

    @Test func questionDetectionSkipsFallbackWhenPunctuationPresent() {
        let service = QuestionDetectionService()
        let text = "This is a statement. Another sentence!"
        let results = service.detectQuestions(in: text)
        #expect(results.isEmpty)
    }

    @Test func questionDetectionSplitsSentencesWithTrailingFragment() {
        let service = QuestionDetectionService()
        let sentences = service.splitIntoSentences("Hello. How are you? trailing text")
        #expect(sentences.count == 3)
        #expect(sentences[0] == "Hello.")
        #expect(sentences[1] == "How are you?")
        #expect(sentences[2] == "trailing text")
    }

    @Test func questionDetectionFirstQuestionPrefersOrder() {
        let service = QuestionDetectionService()
        let first = service.firstQuestion(in: "What is this? How does it work?")
        #expect(first == "What is this?")
    }

    // MARK: - TranscriptBuffer Detection/Pruning Tests

    @Test func transcriptBufferRecentTextFiltersOldAndIncludesPending() {
        let now = Date()
        let buffer = TranscriptBuffer(
            displayWindowSeconds: 60,
            detectionWindowSeconds: 2
        )

        buffer.commitPending(text: "Old sentence.", speaker: .you, at: now.addingTimeInterval(-10))
        buffer.commitPending(text: "New sentence.", speaker: .you, at: now)
        buffer.updatePending(text: "pending text", speaker: .you)

        let recent = buffer.recentTextForDetection(now: now)
        #expect(!recent.contains("Old sentence."))
        #expect(recent.contains("New sentence."))
        #expect(recent.contains("pending text"))
    }

    @Test func transcriptBufferDedupesRecentSentences() {
        let now = Date()
        let buffer = TranscriptBuffer(duplicateWindowSeconds: 5, duplicateCheckCount: 6)

        buffer.commitPending(text: "Hello.", speaker: .you, at: now)
        buffer.commitPending(text: "Hello.", speaker: .you, at: now.addingTimeInterval(1))

        #expect(buffer.displayChunks.count == 1)
        #expect(buffer.displayChunks.first?.text == "Hello.")
    }

    @Test func transcriptBufferPersistsBothSpeakers() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let contents = try transcriptFileContents { buffer in
            buffer.commitPending(text: "Hello world.", speaker: .you, at: now)
            buffer.commitPending(text: "Another line.", speaker: .others, at: now.addingTimeInterval(1))
        }

        #expect(contents.contains("Hello world."))
        #expect(contents.contains("Another line."))
    }

    @Test func transcriptBufferUpdatePendingReplacesRatherThanAppends() {
        let buffer = TranscriptBuffer()

        buffer.updatePending(text: "the quick brown fox jumps", speaker: .you)
        #expect(buffer.displayChunks.count == 1)
        #expect(buffer.displayChunks.first?.text == "the quick brown fox jumps")
        #expect(buffer.displayChunks.first?.isPending == true)

        // A revision, including one shorter than the previous text, replaces wholesale.
        buffer.updatePending(text: "the quick brown fox", speaker: .you)
        #expect(buffer.displayChunks.count == 1)
        #expect(buffer.displayChunks.first?.text == "the quick brown fox")
    }

    @Test func transcriptBufferPendingIsIsolatedPerSpeaker() {
        let buffer = TranscriptBuffer()

        buffer.updatePending(text: "mic in progress", speaker: .you)
        buffer.updatePending(text: "system in progress", speaker: .others)

        #expect(buffer.displayChunks.count == 2)
        let texts = Set(buffer.displayChunks.map(\.text))
        #expect(texts == ["mic in progress", "system in progress"])

        // Revising one speaker's pending text must not disturb the other's.
        buffer.updatePending(text: "mic revised", speaker: .you)
        let othersChunk = buffer.displayChunks.first { $0.speaker == .others }
        #expect(othersChunk?.text == "system in progress")
    }

    @Test func transcriptBufferOnlyCommitPersists() throws {
        let contents = try transcriptFileContents { buffer in
            buffer.updatePending(text: "still speaking, not final yet", speaker: .you)
            buffer.updatePending(text: "still speaking, not final yet either", speaker: .you)
            buffer.commitPending(text: "final utterance.", speaker: .you)
        }

        #expect(!contents.contains("not final yet"))
        #expect(contents.contains("final utterance."))
        #expect(contents.split(separator: "\n").count == 1)
    }

    @Test func transcriptBufferRecentTurnsIncludesBothSpeakersPending() {
        let buffer = TranscriptBuffer()

        buffer.updatePending(text: "you talking", speaker: .you)
        buffer.updatePending(text: "them talking", speaker: .others)

        let turns = buffer.recentTurns()
        #expect(turns.contains { $0.speaker == .you && $0.text == "you talking" })
        #expect(turns.contains { $0.speaker == .others && $0.text == "them talking" })
    }

    // MARK: - AudioQuestionPipeline Retention Tests

    @Test func pipelineDoesNotRepeatAlreadyProcessedQuestions() {
        let pipeline = makePipeline()

        let first = pipeline.process(recentText: "What is this?")
        #expect(first.questions.count == 1)

        let second = pipeline.process(recentText: "What is this?")
        #expect(second.questions.isEmpty)
        #expect(second.latestQuestion == "What is this?")
    }

    @Test func pipelineResetAllowsQuestionAgain() {
        let pipeline = makePipeline()

        _ = pipeline.process(recentText: "What is this?")
        pipeline.reset()
        let result = pipeline.process(recentText: "What is this?")
        #expect(result.questions.count == 1)
    }

    @Test func pipelineEvictsOldQuestionsWhenOverLimit() {
        let pipeline = makePipeline()

        let questions = (1...55).map { "What is item \($0)?" }
        let combined = questions.joined(separator: " ")
        let result = pipeline.process(recentText: combined)
        #expect(result.questions.count == 55)

        let afterEviction = pipeline.process(recentText: "What is item 1?")
        #expect(afterEviction.questions.count == 1)
    }

    // MARK: - QAManager Navigation Tests

    @Test func qaManagerNavigationBoundaries() {
        let manager = QAManager()
        #expect(manager.currentItem == nil)
        #expect(manager.canGoPrevious == false)
        #expect(manager.canGoNext == false)

        _ = manager.addQuestion("Q1", source: .manual)
        _ = manager.addQuestion("Q2", source: .manual)

        manager.goToFirst()
        #expect(manager.currentIndex == 0)
        manager.goToPrevious()
        #expect(manager.currentIndex == 0)

        manager.goToLast()
        #expect(manager.currentIndex == 1)
        manager.goToNext()
        #expect(manager.currentIndex == 1)
    }

    // MARK: - LLM Provider/Service Tests

    @Test func llmProviderKeychainKeyFormatIsStable() {
        // Existing users' stored keys are addressed by this format; changing it would orphan them.
        for provider in LLMProvider.allCases where !provider.usesOAuth {
            #expect(provider.keychainKey == "\(provider.rawValue)_api_key")
        }
    }

    @Test func parseOpenAIFormatCoversEveryBranch() {
        #expect(BaseLLMService.parseOpenAIFormat(#"data: {"choices":[{"delta":{"content":"Hello"}}]}"#) == "Hello")
        #expect(BaseLLMService.parseOpenAIFormat(#"data: {"choices":[{"message":{"content":"Hello"}}]}"#) == "Hello")
        #expect(BaseLLMService.parseOpenAIFormat("data: [DONE]") == "[DONE]")
        #expect(BaseLLMService.parseOpenAIFormat("event: ping") == nil)
    }

    @Test func claudeServiceParsesStreamLine() {
        let service = ClaudeService(
            apiKey: "test",
            model: LLMModelCatalog.option(provider: .claude, modelId: "claude-sonnet-5"),
            thinkingLevel: .high
        )
        let line = "data: {\"delta\":{\"text\":\"Hello\"}}"
        #expect(service.parseStreamLine(line) == "Hello")
        #expect(service.isStreamDone("[DONE]") == false)
    }

    @Test func geminiServiceParsesStreamLineAndBuildURL() {
        let service = GeminiService(
            apiKey: "abc123",
            model: LLMModelCatalog.option(provider: .gemini, modelId: "gemini-3.5-flash-lite"),
            thinkingLevel: .high
        )
        let line = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi\"}]}}]}"
        #expect(service.parseStreamLine(line) == "Hi")
        #expect(service.buildURL()?.absoluteString.contains("key=abc123") == true)
        #expect(service.buildURL()?.absoluteString.contains("gemini-3.5-flash-lite") == true)
    }

    // MARK: - Transcription / stream helpers

    @Test func transcriptionTextUtilsRootMeanSquare() {
        let rms = TranscriptionTextUtils.rootMeanSquare(of: [1.0, -1.0])
        #expect(abs(Double(rms) - 1.0) < 0.001)
        #expect(TranscriptionTextUtils.rootMeanSquare(of: []) == 0)
    }

    @Test func transcriptionTextUtilsBoundarySmoothingTrimsOverlap() {
        // `addition` must start with the last up-to-48 chars of `existing` for overlap trim.
        let existing = "hello world"
        let addition = "hello world continued"
        let merged = TranscriptionTextUtils.appendWithBoundarySmoothing(existing, addition)
        #expect(merged == "hello world continued")
        #expect(!merged.contains("hello world hello world"))
    }

    @Test func transcriptionTextUtilsNormalizeSystemTextAddsPeriod() {
        let out = TranscriptionTextUtils.normalizeSystemText("no period")
        #expect(out.hasSuffix("."))
    }

    @Test func joinTailWithinBudgetKeepsMostRecentLinesInOrder() {
        let lines = ["first", "second", "third", "fourth"]
        let result = TranscriptionTextUtils.joinTailWithinBudget(lines, charBudget: 13)
        #expect(result == "third\nfourth")
    }

    @Test func joinTailWithinBudgetRespectsMaxItems() {
        let lines = ["a", "b", "c", "d"]
        let result = TranscriptionTextUtils.joinTailWithinBudget(lines, charBudget: 1000, maxItems: 2)
        #expect(result == "c\nd")
    }

    @Test func joinTailWithinBudgetHandlesEmptyInput() {
        #expect(TranscriptionTextUtils.joinTailWithinBudget([], charBudget: 100).isEmpty)
        #expect(TranscriptionTextUtils.joinTailWithinBudget(["x"], charBudget: 0).isEmpty)
    }

    @Test func sseDataPayloadStripsPrefix() {
        #expect(LLMStreamHelpers.sseDataPayload(from: "data: {\"x\":1}") == "{\"x\":1}")
        #expect(LLMStreamHelpers.sseDataPayload(from: "not data") == nil)
    }

    @Test func sseDataPayloadPreservesEmbeddedDataSubstring() {
        let line = #"data: {"hint":"data:embedded"}"#
        #expect(LLMStreamHelpers.sseDataPayload(from: line) == #"{"hint":"data:embedded"}"#)
    }

    @Test func llmModelCatalogChatgptIsOpenAISubset() {
        let openaiIds = Set(LLMModelCatalog.models(for: .openai).map(\.id))
        let chatgptIds = Set(LLMModelCatalog.models(for: .chatgpt).map(\.id))
        #expect(!chatgptIds.isEmpty)
        #expect(chatgptIds.isSubset(of: openaiIds))
    }

    // MARK: - PromptBuilder Tests

    @Test func promptBuilderUsesEmptyTranscriptFallback() {
        let builder = PromptBuilder()
        let buffer = TranscriptBuffer()

        let payload = builder.build(mode: .sayNext, transcript: buffer, qaHistory: [])

        #expect(payload.userMessage.contains("(nothing heard yet)"))
        #expect(payload.userMessage.contains("What should I say next?"))
        #expect(payload.options.maxTokens == 512)
    }

    @Test func promptBuilderMergesConsecutiveSameSpeakerTurns() {
        let builder = PromptBuilder()
        let buffer = TranscriptBuffer()
        buffer.commitPending(text: "Hello there. General question.", speaker: .you)

        let payload = builder.build(mode: .answerQuestion, transcript: buffer, qaHistory: [], detectedQuestion: "What?")

        #expect(payload.userMessage.contains("You: Hello there. General question."))
        // Merged into a single "You:" line, not two separate ones.
        #expect(payload.userMessage.components(separatedBy: "You:").count == 2)
    }

    @Test func promptBuilderTruncatesTranscriptToCharBudgetAtTurnBoundary() {
        let builder = PromptBuilder()
        let buffer = TranscriptBuffer(displayWindowSeconds: 6000)
        let now = Date()

        // followUps has a 6000-char budget; generate well over that, oldest first.
        for i in 0..<400 {
            buffer.commitPending(text: "Filler sentence number \(i).", speaker: .you, at: now.addingTimeInterval(Double(i)))
        }

        let payload = builder.build(mode: .followUps, transcript: buffer, qaHistory: [])

        #expect(!payload.userMessage.contains("Filler sentence number 0."))
        #expect(payload.userMessage.contains("Filler sentence number 399."))
        #expect(payload.userMessage.contains("Suggest follow-up questions."))
    }

    @Test func promptBuilderIncludesQAHistoryForAnswerQuestionAndAsk() {
        let builder = PromptBuilder()
        let buffer = TranscriptBuffer()
        var history: [QAItem] = []
        var answered = QAItem(question: "Earlier question?", source: .manual)
        answered.answer = "Earlier answer."
        history.append(answered)

        let payload = builder.build(mode: .answerQuestion, transcript: buffer, qaHistory: history, detectedQuestion: "New question?")

        #expect(payload.userMessage.contains("Earlier in this session you already answered:"))
        #expect(payload.userMessage.contains("Q: Earlier question?"))
        #expect(payload.userMessage.contains("A: Earlier answer."))
    }

    @Test func promptBuilderExcludesUnansweredAndErroredItemsFromQAHistory() {
        let builder = PromptBuilder()
        let buffer = TranscriptBuffer()
        var history: [QAItem] = []
        history.append(QAItem(question: "Unanswered?", source: .manual))
        var errored = QAItem(question: "Failed?", source: .manual)
        errored.answer = "Error: something went wrong"
        history.append(errored)

        let payload = builder.build(mode: .ask, transcript: buffer, qaHistory: history, typedText: "New ask")

        #expect(!payload.userMessage.contains("Earlier in this session you already answered:"))
    }

    @Test func promptBuilderSolveScreenOmitsTranscriptSection() {
        let builder = PromptBuilder()
        let buffer = TranscriptBuffer()
        buffer.commitPending(text: "Some spoken context.", speaker: .you)

        let payload = builder.build(mode: .solveScreen, transcript: buffer, qaHistory: [])

        #expect(!payload.userMessage.contains("Recent conversation:"))
        #expect(payload.userMessage == "Solve the coding problem shown in the screenshot.")
    }

    @Test func promptBuilderAskModeClosingLineIncludesTypedText() {
        let builder = PromptBuilder()
        let buffer = TranscriptBuffer()

        let payload = builder.build(mode: .ask, transcript: buffer, qaHistory: [], typedText: "What time is it?")

        #expect(payload.userMessage.contains("Question: What time is it?"))
    }

    // MARK: - Onboarding flow

    @Test func onboardingStartsAtWelcomeOnAFreshInstall() {
        let readiness = readiness(permissions: false, speechModel: false, credential: false)

        #expect(readiness.isUntouched)
        #expect(OnboardingStep.initial(for: readiness) == .welcome)
    }

    @Test func onboardingResumesAtTheFirstMissingRequirement() {
        let missingModel = readiness(permissions: true, speechModel: false, credential: false)
        #expect(OnboardingStep.initial(for: missingModel) == .speech)

        let missingCredential = readiness(permissions: true, speechModel: true, credential: false)
        #expect(OnboardingStep.initial(for: missingCredential) == .ai)
    }

    /// A later requirement being met doesn't let an earlier gap be skipped.
    @Test func onboardingResumesAtPermissionsEvenWhenLaterStepsAreDone() {
        let readiness = readiness(permissions: false, speechModel: true, credential: true)

        #expect(OnboardingStep.initial(for: readiness) == .permissions)
    }

    @Test func onboardingLandsOnReadyWhenEverythingIsConfigured() {
        let readiness = readiness(permissions: true, speechModel: true, credential: true)

        #expect(readiness.isComplete)
        #expect(OnboardingStep.initial(for: readiness) == .ready)
        #expect(OnboardingStep.firstIncomplete(for: readiness) == .ready)
    }

    @Test func onboardingBookendStepsNeverGateContinue() {
        let readiness = readiness(permissions: false, speechModel: false, credential: false)

        #expect(OnboardingStep.welcome.isSatisfied(by: readiness))
        #expect(OnboardingStep.ready.isSatisfied(by: readiness))
        #expect(!OnboardingStep.permissions.isSatisfied(by: readiness))
        #expect(!OnboardingStep.speech.isSatisfied(by: readiness))
        #expect(!OnboardingStep.ai.isSatisfied(by: readiness))
    }

    @Test func onboardingStepsAreLinkedInOrder() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.ready.next == nil)
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.permissions.next == .speech)
        #expect(OnboardingStep.speech.next == .ai)
        #expect(OnboardingStep.ai.next == .ready)
        #expect(OnboardingStep.ready.previous == .ai)
    }

    // MARK: - Thinking level

    private func claudeBody(modelId: String, level: ThinkingLevel) -> [String: Any] {
        let model = LLMModelCatalog.option(provider: .claude, modelId: modelId)
        let service = ClaudeService(apiKey: "test-key", model: model, thinkingLevel: level)
        return service.buildTextRequestBody(
            userMessage: "hi",
            systemPrompt: "sys",
            options: PromptMode.answerQuestion.options
        )
    }

    @Test func claudeRequestSendsAdaptiveThinking() {
        let body = claudeBody(modelId: "claude-sonnet-5", level: .high)

        #expect((body["thinking"] as? [String: String])?["type"] == "adaptive")
        #expect((body["output_config"] as? [String: String])?["effort"] == "high")
    }

    @Test func claudeRequestOmitsThinkingForModelWithoutEffortSupport() {
        let model = LLMModelOption(id: "claude-legacy", supportsVision: true, supportsThinkingLevel: false)
        let service = ClaudeService(apiKey: "test-key", model: model, thinkingLevel: .high)
        let body = service.buildTextRequestBody(
            userMessage: "hi",
            systemPrompt: "sys",
            options: PromptMode.answerQuestion.options
        )

        #expect(body["thinking"] == nil)
        #expect(body["output_config"] == nil)
    }

    @Test func openAIRequestUsesMaxCompletionTokensAndReasoningEffort() {
        let model = LLMModelCatalog.option(provider: .openai, modelId: "gpt-6-luna")
        let service = OpenAIService(apiKey: "test-key", model: model, thinkingLevel: .low)

        let body = service.buildTextRequestBody(
            userMessage: "hi",
            systemPrompt: "sys",
            options: PromptMode.answerQuestion.options
        )

        #expect(body["max_completion_tokens"] as? Int == 2048)
        #expect(body["max_tokens"] == nil)
        #expect(body["reasoning_effort"] as? String == "low")
    }

    @Test func geminiRequestCarriesThinkingLevel() {
        let model = LLMModelCatalog.option(provider: .gemini, modelId: "gemini-3.7-flash")
        let service = GeminiService(apiKey: "test-key", model: model, thinkingLevel: .medium)

        let body = service.buildTextRequestBody(
            userMessage: "hi",
            systemPrompt: "sys",
            options: PromptMode.answerQuestion.options
        )
        let config = body["generationConfig"] as? [String: Any]

        #expect((config?["thinkingConfig"] as? [String: String])?["thinkingLevel"] == "MEDIUM")
        #expect(config?["temperature"] == nil)
    }

    @Test func geminiStreamParsingSkipsThoughtParts() {
        let model = LLMModelCatalog.option(provider: .gemini, modelId: "gemini-3.7-flash")
        let service = GeminiService(apiKey: "test-key", model: model, thinkingLevel: .high)
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"pondering","thought":true},{"text":"answer"}]}}]}"#

        #expect(service.parseStreamLine(line) == "answer")
    }

    @Test func chatGPTRequestCarriesReasoningEffort() {
        let model = LLMModelCatalog.option(provider: .chatgpt, modelId: "gpt-6-sol")
        let service = ChatGPTService(
            model: model,
            thinkingLevel: .medium,
            authManager: ChatGPTAuthManager()
        )

        let body = service.buildResponsesBody(
            instructions: "sys",
            content: [["type": "input_text", "text": "hi"]]
        )

        #expect((body["reasoning"] as? [String: String])?["effort"] == "medium")
    }

    @Test func thinkingLevelRoundTripsAndFallsBackToHigh() {
        let key = UserDefaultsKeys.thinkingLevel(for: .claude)
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(ThinkingLevel.load(for: .claude) == .high)

        UserDefaults.standard.set("ludicrous", forKey: key)
        #expect(ThinkingLevel.load(for: .claude) == .high)

        ThinkingLevel.save(.low, for: .claude)
        #expect(ThinkingLevel.load(for: .claude) == .low)
    }
}
