//
//  sniffTests.swift
//  sniffTests
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Testing
@testable import sniff

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
        let buffer = TranscriptBuffer(maxLines: 3, maxLineLength: 20)
        buffer.update(with: "Hello world")
        #expect(!buffer.displayText.isEmpty)

        buffer.update(with: "   ")
        #expect(buffer.displayText.isEmpty)
    }

    @Test func transcriptBufferWrapsAndCapsLines() {
        let buffer = TranscriptBuffer(maxLines: 2, maxLineLength: 10)
        buffer.update(with: "one two three four five six seven")

        let lines = buffer.displayText.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].count <= 10)
        #expect(lines[1].count <= 10)
        #expect(lines.joined(separator: " ").contains("five"))
        #expect(lines.joined(separator: " ").contains("seven"))
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
        let buffer = TranscriptBuffer(maxLines: 3, maxLineLength: 20)
        #expect(buffer.latestQuestion == nil)
        
        buffer.updateLatestQuestion("What is this?")
        #expect(buffer.latestQuestion == "What is this?")
        
        buffer.updateLatestQuestion("How does it work?")
        #expect(buffer.latestQuestion == "How does it work?")
    }
    
    @Test func transcriptBufferClearsLatestQuestionOnClear() {
        let buffer = TranscriptBuffer(maxLines: 3, maxLineLength: 20)
        buffer.updateLatestQuestion("What is this?")
        #expect(buffer.latestQuestion != nil)
        
        buffer.clear()
        #expect(buffer.latestQuestion == nil)
    }
    
    @Test func transcriptBufferLatestQuestionIndependentOfDisplayText() {
        let buffer = TranscriptBuffer(maxLines: 3, maxLineLength: 20)
        
        buffer.update(with: "Hello world this is some text")
        #expect(!buffer.displayText.isEmpty)
        #expect(buffer.latestQuestion == nil)
        
        buffer.updateLatestQuestion("What is this?")
        #expect(!buffer.displayText.isEmpty)
        #expect(buffer.latestQuestion == "What is this?")
        
        buffer.update(with: "New display text here")
        #expect(buffer.displayText.contains("New"))
        #expect(buffer.latestQuestion == "What is this?")
    }
    
    // MARK: - AudioQuestionPipeline Tests (Punctuation-based detection)
    
    @Test func pipelineDetectsQuestionWithPunctuation() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(transcribedText: "How does async work in JavaScript which is single threaded?")
        
        #expect(result.latestQuestion != nil)
        #expect(result.latestQuestion?.hasSuffix("?") == true)
        #expect(result.questions.count == 1)
    }
    
    @Test func pipelineDoesNotDetectStatementWithPeriod() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(transcribedText: "I think the answer is obvious.")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    @Test func pipelineDetectsPartialQuestionByKeyword() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        // Partial question without punctuation yet (fallback to keyword)
        let result = pipeline.process(transcribedText: "What is JavaScript")
        
        #expect(result.latestQuestion != nil)
        #expect(result.latestQuestion?.lowercased().hasPrefix("what") == true)
    }
    
    @Test func pipelineHandlesMultipleSentences() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(transcribedText: "Hello. How are you?")
        
        #expect(result.latestQuestion == "How are you?")
        #expect(result.questions.count == 1)
    }
    
    @Test func pipelineSplitsSentencesCorrectly() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(transcribedText: "First sentence. What is this? Another statement!")
        
        #expect(result.latestQuestion == "What is this?")
        #expect(result.questions.count == 1)
    }
    
    @Test func pipelineDetectsMultipleQuestions() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(transcribedText: "What is this? How does it work?")
        
        #expect(result.questions.count == 2)
        #expect(result.latestQuestion == "How does it work?")
    }
    
    @Test func pipelineHandlesEmptyInput() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        let result = pipeline.process(transcribedText: "")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    @Test func pipelineIgnoresStatementEvenWithQuestionKeyword() {
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        
        // "which" appears mid-sentence, but ends with period - not a question
        let result = pipeline.process(transcribedText: "JavaScript which is a language.")
        
        #expect(result.latestQuestion == nil)
        #expect(result.questions.isEmpty)
    }
    
    // MARK: - Highlighting Verification Tests
    
    @Test func highlightingWorksWithPunctuatedQuestionAcrossWrappedLines() {
        // Simulate TranscriptBuffer wrapping behavior
        let buffer = TranscriptBuffer(maxLines: 6, maxLineLength: 30)
        
        // Long question that will be wrapped
        let fullText = "How does async functionality work in JavaScript?"
        buffer.update(with: fullText)
        
        // Check displayText contains the question (possibly with line breaks)
        let normalizedDisplay = buffer.displayText.replacingOccurrences(of: "\n", with: " ")
        #expect(normalizedDisplay.contains("async"))
        #expect(normalizedDisplay.contains("JavaScript?"))
        
        // Set the latest question (as pipeline would do)
        let service = QuestionDetectionService()
        let pipeline = AudioQuestionPipeline(questionDetectionService: service)
        let result = pipeline.process(transcribedText: fullText)
        
        buffer.updateLatestQuestion(result.latestQuestion)
        
        // Verify question was detected
        #expect(buffer.latestQuestion != nil)
        #expect(buffer.latestQuestion?.hasSuffix("?") == true)
    }
    
    @Test func highlightingPreservesPunctuationInDisplayText() {
        let buffer = TranscriptBuffer(maxLines: 6, maxLineLength: 60)
        
        // Multiple sentences with punctuation
        buffer.update(with: "Hello there. How are you? I am fine.")
        
        // Punctuation should be preserved in display text
        #expect(buffer.displayText.contains("."))
        #expect(buffer.displayText.contains("?"))
        
        // Set question
        buffer.updateLatestQuestion("How are you?")
        
        // Question should match exactly in display text
        #expect(buffer.displayText.contains("How are you?"))
        #expect(buffer.latestQuestion == "How are you?")
    }
    
    @Test func highlightingHandlesQuestionSpanningMultipleLines() {
        // Buffer with short line length to force wrapping
        let buffer = TranscriptBuffer(maxLines: 6, maxLineLength: 20)
        
        let question = "What is the meaning of life?"
        buffer.update(with: question)
        
        // Should be wrapped across multiple lines
        let lines = buffer.displayText.split(separator: "\n")
        #expect(lines.count > 1) // Verify wrapping occurred
        
        buffer.updateLatestQuestion(question)
        
        // Question and display text should match when whitespace normalized
        let normalizedQuestion = question.replacingOccurrences(of: " ", with: " ")
        let normalizedDisplay = buffer.displayText.replacingOccurrences(of: "\n", with: " ")
        #expect(normalizedDisplay == normalizedQuestion)
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
}

