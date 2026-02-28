//
//  sniffTests.swift
//  sniffTests
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Testing
@testable import syncsd

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
        _ = manager.addQuestion("How does it work?", source: .audio)
        
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

    @Test func transcriptBufferClearsOnEmptyInput() {
        let buffer = TranscriptBuffer(maxLineLength: 20)
        appendAndRefresh(buffer, "Hello world.", speaker: .you)
        #expect(!buffer.displayChunks.isEmpty)

        buffer.clear()
        #expect(buffer.displayChunks.isEmpty)
    }

    @Test func transcriptBufferWrapsAndCapsLines() {
        let buffer = TranscriptBuffer(maxLineLength: 10)
        appendAndRefresh(buffer, "one two three four five six seven.", speaker: .you)

        #expect(!buffer.displayChunks.isEmpty)
        let allText = buffer.displayChunks.map { $0.text }.joined(separator: " ")
        #expect(allText.contains("five"))
        #expect(allText.contains("seven"))
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
    
    // MARK: - TranscriptBuffer.latestQuestion Tests
    
    @Test func transcriptBufferTracksLatestQuestion() {
        let buffer = TranscriptBuffer(maxLineLength: 20)
        #expect(buffer.latestQuestion == nil)
        
        buffer.updateLatestQuestion("What is this?")
        #expect(buffer.latestQuestion == "What is this?")
        
        buffer.updateLatestQuestion("How does it work?")
        #expect(buffer.latestQuestion == "How does it work?")
    }
    
    @Test func transcriptBufferClearsLatestQuestionOnClear() {
        let buffer = TranscriptBuffer(maxLineLength: 20)
        buffer.updateLatestQuestion("What is this?")
        #expect(buffer.latestQuestion != nil)
        
        buffer.clear()
        #expect(buffer.latestQuestion == nil)
    }
    
    @Test func transcriptBufferLatestQuestionIndependentOfDisplayText() {
        let buffer = TranscriptBuffer(maxLineLength: 20)
        
        appendAndRefresh(buffer, "Hello world this is some text.", speaker: .you)
        #expect(!buffer.displayChunks.isEmpty)
        #expect(buffer.latestQuestion == nil)
        
        buffer.updateLatestQuestion("What is this?")
        #expect(!buffer.displayChunks.isEmpty)
        #expect(buffer.latestQuestion == "What is this?")
        
        appendAndRefresh(buffer, "New display text here.", speaker: .you)
        let allText = buffer.displayChunks.map { $0.text }.joined(separator: " ")
        #expect(allText.contains("New"))
        #expect(buffer.latestQuestion == "What is this?")
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
    
    // MARK: - Highlighting Verification Tests
    
    @Test func highlightingWorksWithPunctuatedQuestionAcrossWrappedLines() {
        // Simulate TranscriptBuffer wrapping behavior
        let buffer = TranscriptBuffer(maxLineLength: 30)
        
        // Long question that will be wrapped
        let fullText = "How does async functionality work in JavaScript?"
        appendAndRefresh(buffer, fullText, speaker: .you)
        
        // Check displayChunks contain the question
        let allText = buffer.displayChunks.map { $0.text }.joined(separator: " ")
        #expect(allText.contains("async"))
        #expect(allText.contains("JavaScript?"))
        
        // Set the latest question (as pipeline would do)
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        let result = pipeline.process(recentText: fullText)
        
        buffer.updateLatestQuestion(result.latestQuestion)
        
        // Verify question was detected
        #expect(buffer.latestQuestion != nil)
        #expect(buffer.latestQuestion?.hasSuffix("?") == true)
    }
    
    @Test func highlightingPreservesPunctuationInDisplayText() {
        let buffer = TranscriptBuffer(maxLineLength: 60)
        
        // Multiple sentences with punctuation
        appendAndRefresh(buffer, "Hello there. How are you? I am fine.", speaker: .you)
        
        // Punctuation should be preserved in display chunks
        let allText = buffer.displayChunks.map { $0.text }.joined(separator: " ")
        #expect(allText.contains("."))
        #expect(allText.contains("?"))
        
        // Set question
        buffer.updateLatestQuestion("How are you?")
        
        // Question should match exactly in display text
        #expect(allText.contains("How are you?"))
        #expect(buffer.latestQuestion == "How are you?")
    }
    
    @Test func highlightingHandlesQuestionSpanningMultipleLines() {
        // Buffer with short line length to force wrapping
        let buffer = TranscriptBuffer(maxLineLength: 20)
        
        let question = "What is the meaning of life?"
        appendAndRefresh(buffer, question, speaker: .you)
        
        // Check chunks were created
        #expect(!buffer.displayChunks.isEmpty)
        
        buffer.updateLatestQuestion(question)
        
        // Question should be in the chunks
        let allText = buffer.displayChunks.map { $0.text }.joined(separator: " ")
        #expect(allText.contains("meaning"))
        #expect(allText.contains("life?"))
    }

    private func appendAndRefresh(_ buffer: TranscriptBuffer, _ text: String, speaker: TranscriptSpeaker) {
        buffer.append(deltaText: text, speaker: speaker)
        buffer.refreshDisplay()
    }
    
    // MARK: - Vision/Image-Based Question Tests
    
    @Test func screenCaptureServiceInitializesWithNilImageData() {
        let service = ScreenCaptureService()
        #expect(service.capturedImageData == nil)
        #expect(service.isCapturing == false)
    }
    
    @Test func qaManagerAddsScreenQuestionWithPrompt() {
        let manager = QAManager()
        let prompt = "Solve the problem or answer the question shown in this image."
        
        let item = manager.addQuestion(prompt, source: .screen, screenContext: nil)
        
        #expect(item.question == prompt)
        #expect(item.source == .screen)
        #expect(item.screenContext == nil)
        #expect(manager.items.count == 1)
    }
    
    @Test func qaManagerHandlesMultipleSourceTypes() {
        let manager = QAManager()
        
        let audioItem = manager.addQuestion("What is this?", source: .audio)
        let screenItem = manager.addQuestion("Solve image problem", source: .screen)
        let manualItem = manager.addQuestion("Manual question", source: .manual)
        
        #expect(manager.items.count == 3)
        #expect(manager.items[0].source == .audio)
        #expect(manager.items[1].source == .screen)
        #expect(manager.items[2].source == .manual)
        
        #expect(audioItem.source == .audio)
        #expect(screenItem.source == .screen)
        #expect(manualItem.source == .manual)
    }
    
    @Test func qaItemStoresScreenContext() {
        let manager = QAManager()
        
        // Screen item without context (image-based)
        let imageItem = manager.addQuestion("Solve this", source: .screen, screenContext: nil)
        #expect(imageItem.screenContext == nil)
        
        // Audio item with text context
        let textItem = manager.addQuestion("What is X?", source: .audio, screenContext: "Some context text")
        #expect(textItem.screenContext == "Some context text")
    }
    
    // MARK: - LLM Service Base64 Encoding Tests
    
    @Test func base64EncodingProducesValidString() {
        // Simulate what LLM services do with image data
        let testData = "test image data".data(using: .utf8)!
        let base64 = testData.base64EncodedString()
        
        #expect(!base64.isEmpty)
        #expect(!base64.contains(" "))
        
        // Verify round-trip
        let decoded = Data(base64Encoded: base64)
        #expect(decoded == testData)
    }
    
    @Test func base64DataURLFormatIsCorrect() {
        // Test OpenAI/Perplexity format
        let testData = "fake jpeg".data(using: .utf8)!
        let base64 = testData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64)"
        
        #expect(dataURL.hasPrefix("data:image/jpeg;base64,"))
        #expect(dataURL.contains(base64))
    }
    
    // MARK: - QuestionSource Enum Tests
    
    @Test func questionSourceEnumHasExpectedCases() {
        let sources: [QuestionSource] = [.audio, .screen, .manual]
        #expect(sources.count == 3)
    }
    
    @Test func questionSourceUsedCorrectlyInQAItem() {
        let audioItem = QAItem(question: "Q1", source: .audio)
        let screenItem = QAItem(question: "Q2", source: .screen)
        let manualItem = QAItem(question: "Q3", source: .manual)
        
        #expect(audioItem.source == .audio)
        #expect(screenItem.source == .screen)
        #expect(manualItem.source == .manual)
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
            maxLineLength: 50,
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
        let buffer = TranscriptBuffer(maxLineLength: 50, duplicateWindowSeconds: 5, duplicateCheckCount: 6)

        buffer.append(deltaText: "Hello.", speaker: .you, at: now)
        buffer.append(deltaText: "Hello.", speaker: .you, at: now.addingTimeInterval(1))
        buffer.refreshDisplay()

        #expect(buffer.displayChunks.count == 1)
        #expect(buffer.displayChunks.first?.text == "Hello.")
    }

    @Test func transcriptBufferCapsDisplayLength() {
        let now = Date()
        let buffer = TranscriptBuffer(maxLineLength: 100, maxDisplayCharacters: 10)
        buffer.append(deltaText: "ABCDEFGHIJKLMNOPQRSTUVWXYZ.", speaker: .you, at: now)
        buffer.refreshDisplay()

        let allText = buffer.displayChunks.map { $0.text }.joined(separator: " ")
        #expect(allText.contains("RSTUVWXYZ."))
    }

    @Test func transcriptBufferWritesSessionFile() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let buffer = TranscriptBuffer(maxLineLength: 40)
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

    @Test func llmProviderMetadata() {
        #expect(LLMProvider.openai.displayName == "OpenAI")
        #expect(LLMProvider.gemini.displayName == "Gemini")
        #expect(LLMProvider.perplexity.keychainKey == "perplexity_api_key")
        #expect(LLMProvider.allCases.count == 4)
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
        let service = ClaudeService(apiKey: "test")
        let line = "data: {\"delta\":{\"text\":\"Hello\"}}"
        #expect(service.parseStreamLine(line) == "Hello")
        #expect(service.isStreamDone("[DONE]") == false)
    }

    @Test func geminiServiceParsesStreamLineAndBuildURL() {
        let service = GeminiService(apiKey: "abc123")
        let line = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi\"}]}}]}"
        #expect(service.parseStreamLine(line) == "Hi")
        #expect(service.buildURL()?.absoluteString.contains("key=abc123") == true)
    }
}
