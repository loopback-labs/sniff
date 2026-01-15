//
//  sniffTests.swift
//  sniffTests
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Testing
@testable import sniff

@MainActor
struct sniffTests {

    @Test func screenDetectionFindsQuestionsWithPunctuation() {
        let service = QuestionDetectionService()
        let text = "This is a statement. What is this? Another?"
        let results = service.detectFromScreen(text)
        
        #expect(results.contains("What is this?"))
        #expect(results.contains("Another?"))
    }
    
    @Test func audioDetectionFindsQuestionsWithoutPunctuation() {
        let service = QuestionDetectionService()
        let text = "how does this work please explain the steps"
        let results = service.detectFromAudio(text)
        
        #expect(results.contains { $0.lowercased().hasPrefix("how does this work") })
    }
    
    @Test func screenDetectionDedupes() {
        let service = QuestionDetectionService()
        let text = "What is this? what is this?"
        let results = service.detectFromScreen(text)
        
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

    @Test func perplexityStreamLineParsing() {
        let line = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
        let parsed = PerplexityService.parseStreamLine(line)
        #expect(parsed == "Hello")

        let done = PerplexityService.parseStreamLine("data: [DONE]")
        #expect(done == "[DONE]")
    }
    
    // MARK: - Delta-based Question Detection Tests
    
    @Test func deltaDetectionExtractsOnlyNewQuestions() {
        let detector = QuestionDetectionService()
        let processor = TranscriptionDeltaProcessor()
        
        // First update - should detect question
        let firstDelta = processor.consume("what is the weather")
        let questions1 = detector.detectFromAudio(firstDelta)
        #expect(questions1.count == 1)
        #expect(questions1.first?.lowercased().contains("weather") == true)
        
        // Second update - extending same question, no question words in delta
        let secondDelta = processor.consume("what is the weather today")
        let questions2 = detector.detectFromAudio(secondDelta)
        #expect(questions2.isEmpty)
        
        // Third update - new question, should detect
        let thirdDelta = processor.consume("what is the weather today how does it work")
        let questions3 = detector.detectFromAudio(thirdDelta)
        #expect(questions3.count == 1)
        #expect(questions3.first?.lowercased().contains("how does") == true)
    }
    
    @Test func deltaDetectionHandlesEmptyStrings() {
        let detector = QuestionDetectionService()
        let processor = TranscriptionDeltaProcessor()
        
        _ = processor.consume("something")
        let emptyDelta = processor.consume("")
        #expect(detector.detectFromAudio(emptyDelta).isEmpty)
        
        let freshProcessor = TranscriptionDeltaProcessor()
        let firstDelta = freshProcessor.consume("what is this")
        #expect(detector.detectFromAudio(firstDelta).count == 1)
        
        let emptyProcessor = TranscriptionDeltaProcessor()
        let emptyDelta2 = emptyProcessor.consume("")
        #expect(detector.detectFromAudio(emptyDelta2).isEmpty)
    }
    
    @Test func deltaDetectionHandlesRecognitionRestart() {
        let detector = QuestionDetectionService()
        let processor = TranscriptionDeltaProcessor()
        
        _ = processor.consume("what is the capital of france")
        let restartDelta = processor.consume("what is the capital")
        let questions = detector.detectFromAudio(restartDelta)
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
}

