//
//  sniffTests.swift
//  sniffTests
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Combine
import Testing
@testable import Sniff

@MainActor
struct sniffTests {

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
        appendAndRefresh(buffer, "Hello world.", speaker: .you)
        buffer.updateLatestQuestion("What is this?")
        #expect(!buffer.displayChunks.isEmpty)

        buffer.clear()
        #expect(buffer.displayChunks.isEmpty)
        #expect(buffer.latestQuestion == nil)
    }

    @Test func openAIFormatStreamLineParsing() {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
        let parsed = BaseLLMService.parseOpenAIFormat(line)
        #expect(parsed == "Hello")

        let done = BaseLLMService.parseOpenAIFormat("data: [DONE]")
        #expect(done == "[DONE]")
    }
    
    // MARK: - Delta-based Question Detection Tests
    
    @Test func deltaDetectionExtractsOnlyNewQuestions() {
        let detector = QuestionDetectionService()
        let processor = TranscriptionDeltaProcessor()
        
        // First update - should detect question
        let firstDelta = processor.consume("what is the weather")
        let questions1 = detector.detectQuestions(in: firstDelta)
        #expect(questions1.count == 1)
        #expect(questions1.first?.lowercased().contains("weather") == true)
        
        // Second update - extending same question, no question words in delta
        let secondDelta = processor.consume("what is the weather today")
        let questions2 = detector.detectQuestions(in: secondDelta)
        #expect(questions2.isEmpty)
        
        // Third update - new question, should detect
        let thirdDelta = processor.consume("what is the weather today how does it work")
        let questions3 = detector.detectQuestions(in: thirdDelta)
        #expect(questions3.count == 1)
        #expect(questions3.first?.lowercased().contains("how does") == true)
    }
    
    @Test func deltaDetectionHandlesEmptyStrings() {
        let detector = QuestionDetectionService()
        let processor = TranscriptionDeltaProcessor()
        
        _ = processor.consume("something")
        let emptyDelta = processor.consume("")
        #expect(detector.detectQuestions(in: emptyDelta).isEmpty)
        
        let freshProcessor = TranscriptionDeltaProcessor()
        let firstDelta = freshProcessor.consume("what is this")
        #expect(detector.detectQuestions(in: firstDelta).count == 1)
        
        let emptyProcessor = TranscriptionDeltaProcessor()
        let emptyDelta2 = emptyProcessor.consume("")
        #expect(detector.detectQuestions(in: emptyDelta2).isEmpty)
    }
    
    @Test func deltaDetectionHandlesRecognitionRestart() {
        let detector = QuestionDetectionService()
        let processor = TranscriptionDeltaProcessor()
        
        _ = processor.consume("what is the capital of france")
        let restartDelta = processor.consume("what is the capital")
        let questions = detector.detectQuestions(in: restartDelta)
        #expect(questions.count == 1)
    }
    
    @Test func transcriptionDeltaProcessorTracksSuffixUpdates() {
        let processor = TranscriptionDeltaProcessor()
        
        let delta1 = processor.consume("hello world")
        #expect(delta1 == "hello world")
        
        let delta2 = processor.consume("hello world how are you")
        #expect(delta2 == "how are you")
        
        let delta3 = processor.consume("hello world how are you")
        #expect(delta3.isEmpty)
    }
    
    @Test func transcriptionDeltaProcessorResetsOnEmptyInput() {
        let processor = TranscriptionDeltaProcessor()
        
        _ = processor.consume("hello world")
        let delta1 = processor.consume("   ")
        #expect(delta1.isEmpty)
        
        let delta2 = processor.consume("hi again")
        #expect(delta2 == "hi again")
    }
    
    // MARK: - AudioQuestionPipeline Tests (Punctuation-based detection)
    
    @Test func pipelineDetectsQuestionWithPunctuation() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(recentText: "How does async work in JavaScript which is single threaded?")
        
        #expect(result.latestQuestion != nil)
        #expect(result.latestQuestion?.hasSuffix("?") == true)
        #expect(result.questions.count == 1)
    }
    
    @Test func pipelineDoesNotDetectStatementWithPeriod() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(recentText: "I think the answer is obvious.")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    @Test func pipelineDetectsPartialQuestionByKeyword() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        // Partial question without punctuation yet (fallback to keyword)
        let result = pipeline.process(recentText: "What is JavaScript")
        
        #expect(result.latestQuestion != nil)
        #expect(result.latestQuestion?.lowercased().hasPrefix("what") == true)
    }
    
    @Test func pipelineHandlesMultipleSentences() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(recentText: "Hello. How are you?")
        
        #expect(result.latestQuestion == "How are you?")
        #expect(result.questions.count == 1)
    }
    
    @Test func pipelineSplitsSentencesCorrectly() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(recentText: "First sentence. What is this? Another statement!")
        
        #expect(result.latestQuestion == "What is this?")
        #expect(result.questions.count == 1)
    }
    
    @Test func pipelineDetectsMultipleQuestions() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(recentText: "What is this? How does it work?")
        
        #expect(result.questions.count == 2)
        #expect(result.latestQuestion == "How does it work?")
    }
    
    @Test func pipelineHandlesEmptyInput() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(recentText: "")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    @Test func pipelineIgnoresStatementEvenWithQuestionKeyword() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        // "which" appears mid-sentence, but ends with period - not a question
        let result = pipeline.process(recentText: "JavaScript which is a language.")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    private func appendAndRefresh(_ buffer: TranscriptBuffer, _ text: String, speaker: TranscriptSpeaker) {
        buffer.append(deltaText: text, speaker: speaker)
        buffer.refreshDisplay()
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

        buffer.append(deltaText: "Old sentence.", speaker: .you, at: now.addingTimeInterval(-10))
        buffer.append(deltaText: "New sentence.", speaker: .you, at: now)
        buffer.append(deltaText: "pending text", speaker: .you, at: now)

        let recent = buffer.recentTextForDetection(now: now)
        #expect(!recent.contains("Old sentence."))
        #expect(recent.contains("New sentence."))
        #expect(recent.contains("pending text"))
    }

    @Test func transcriptBufferDedupesRecentSentences() {
        let now = Date()
        let buffer = TranscriptBuffer(duplicateWindowSeconds: 5, duplicateCheckCount: 6)

        buffer.append(deltaText: "Hello.", speaker: .you, at: now)
        buffer.append(deltaText: "Hello.", speaker: .you, at: now.addingTimeInterval(1))
        buffer.refreshDisplay()

        #expect(buffer.displayChunks.count == 1)
        #expect(buffer.displayChunks.first?.text == "Hello.")
    }

    @Test func transcriptBufferWritesSessionFile() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let buffer = TranscriptBuffer()
        buffer.startSession(saveDirectoryURL: tempDir)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        buffer.append(deltaText: "Hello world.", speaker: .you, at: now)
        buffer.append(deltaText: "Another line.", speaker: .others, at: now.addingTimeInterval(1))
        buffer.stopSession()

        let items = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(items.count == 1)
        let fileURL = tempDir.appendingPathComponent(items[0])
        let contents = try String(contentsOf: fileURL)
        #expect(contents.contains("Hello world."))
        #expect(contents.contains("Another line."))
    }

    // MARK: - AudioQuestionPipeline Retention Tests

    @Test func pipelineDoesNotRepeatAlreadyProcessedQuestions() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)

        let first = pipeline.process(recentText: "What is this?")
        #expect(first.questions.count == 1)

        let second = pipeline.process(recentText: "What is this?")
        #expect(second.questions.isEmpty)
        #expect(second.latestQuestion == "What is this?")
    }

    @Test func pipelineResetAllowsQuestionAgain() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)

        _ = pipeline.process(recentText: "What is this?")
        pipeline.reset()
        let result = pipeline.process(recentText: "What is this?")
        #expect(result.questions.count == 1)
    }

    @Test func pipelineEvictsOldQuestionsWhenOverLimit() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)

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

    @Test func parseOpenAIFormatHandlesMessageContent() {
        let line = "data: {\"choices\":[{\"message\":{\"content\":\"Hello\"}}]}"
        let parsed = BaseLLMService.parseOpenAIFormat(line)
        #expect(parsed == "Hello")
    }

    @Test func parseOpenAIFormatIgnoresNonDataLines() {
        let parsed = BaseLLMService.parseOpenAIFormat("event: ping")
        #expect(parsed == nil)
    }

    @Test func claudeServiceParsesStreamLine() {
        let service = ClaudeService(apiKey: "test", model: "claude-sonnet-4-6")
        let line = "data: {\"delta\":{\"text\":\"Hello\"}}"
        #expect(service.parseStreamLine(line) == "Hello")
        #expect(service.isStreamDone("[DONE]") == false)
    }

    @Test func geminiServiceParsesStreamLineAndBuildURL() {
        let service = GeminiService(apiKey: "abc123", model: "gemini-2.5-flash")
        let line = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi\"}]}}]}"
        #expect(service.parseStreamLine(line) == "Hi")
        #expect(service.buildURL()?.absoluteString.contains("key=abc123") == true)
        #expect(service.buildURL()?.absoluteString.contains("gemini-2.5-flash") == true)
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

    // MARK: - ScreenCaptureService

    @Test func screenCaptureServiceCaptureFrameWithoutActiveSessionReturnsNil() async {
        let service = ScreenCaptureService()
        let frame = await service.captureCurrentFrame()
        #expect(frame == nil)
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
        appendAndRefresh(buffer, "Hello there. General question.", speaker: .you)

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
            buffer.append(deltaText: "Filler sentence number \(i).", speaker: .you, at: now.addingTimeInterval(Double(i)))
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
        appendAndRefresh(buffer, "Some spoken context.", speaker: .you)

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
}
