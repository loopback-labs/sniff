//
//  AudioQuestionPipeline.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

@MainActor
class AudioQuestionPipeline {
    private let questionDetectionService: QuestionDetectionService
    
    // Question keywords for fallback when punctuation isn't available
    private let questionKeywords = ["what", "who", "when", "where", "why", "how", "which", "whose", "whom"]
    
    init(questionDetectionService: QuestionDetectionService, windowMaxLength: Int = 500) {
        self.questionDetectionService = questionDetectionService
    }
    
    func process(transcribedText: String) -> (latestQuestion: String?, questions: [String]) {
        guard !transcribedText.isEmpty else {
            return (nil, [])
        }
        
        // Split into sentences (now easy with punctuation from SFSpeechRecognizer)
        let sentences = splitIntoSentences(transcribedText)
        
        // Find questions from the last few sentences
        var questions: [String] = []
        for sentence in sentences.suffix(3) {
            if isQuestion(sentence) {
                questions.append(sentence)
            }
        }
        
        return (questions.last, questions)
    }
    
    private func isQuestion(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        
        // Primary: ends with "?" (from punctuation)
        if trimmed.hasSuffix("?") { return true }
        
        // Fallback: starts with question word (for partial/unpunctuated text)
        let firstWord = trimmed.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return questionKeywords.contains(firstWord)
    }
    
    private func splitIntoSentences(_ text: String) -> [String] {
        // Split on sentence-ending punctuation
        let pattern = "[.!?]+"
        var sentences: [String] = []
        var remaining = text
        
        while let range = remaining.range(of: pattern, options: .regularExpression) {
            let sentence = String(remaining[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            remaining = String(remaining[range.upperBound...])
        }
        
        // Add remaining text (incomplete sentence)
        let leftover = remaining.trimmingCharacters(in: .whitespaces)
        if !leftover.isEmpty {
            sentences.append(leftover)
        }
        
        return sentences
    }
}
