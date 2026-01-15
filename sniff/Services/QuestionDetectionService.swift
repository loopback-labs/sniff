//
//  QuestionDetectionService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
class QuestionDetectionService {
    private let questionWords = ["what", "who", "when", "where", "why", "how", "which", "whose", "whom"]
    private let questionVerbs = ["is", "are", "was", "were", "do", "does", "did", "can", "could", "will", "would", "should", "may", "might"]
    
    func detectQuestions(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        
        // Split by sentence endings but preserve question marks
        var sentences: [String] = []
        var currentSentence = ""
        
        for char in text {
            currentSentence.append(char)
            if char == "." || char == "!" || char == "?" || char == "\n" {
                let trimmed = currentSentence.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                currentSentence = ""
            }
        }
        
        // Add remaining text
        if !currentSentence.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(currentSentence.trimmingCharacters(in: .whitespaces))
        }
        
        var questions: [String] = []
        
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            if isQuestion(trimmed) {
                questions.append(trimmed)
            }
        }

        if questions.isEmpty {
            let fallbackQuestions = detectQuestionsWithoutPunctuation(in: text)
            questions.append(contentsOf: fallbackQuestions)
        }
        
        return dedupe(questions)
    }
    
    private func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        
        // Check for question mark
        if trimmed.hasSuffix("?") {
            return true
        }
        
        // Check for question words at the start
        let lowercased = trimmed.lowercased()
        for word in questionWords {
            if lowercased.hasPrefix("\(word) ") || lowercased == word {
                return true
            }
        }
        
        // Check for question-forming verbs
        for verb in questionVerbs {
            if lowercased.hasPrefix("\(verb) ") {
                return true
            }
        }
        
        return false
    }
    
    private func detectQuestionsWithoutPunctuation(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        let lowercased = trimmed.lowercased()
        let maxTailLength = 400
        let tail = lowercased.suffix(maxTailLength)
        let startIndex = lowercased.index(lowercased.endIndex, offsetBy: -tail.count)
        let originalTail = String(trimmed[startIndex...])
        
        let wordGroup = (questionWords + questionVerbs).joined(separator: "|")
        let pattern = "\\b(\(wordGroup))\\b[^.?!\\n]*"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        
        let range = NSRange(originalTail.startIndex..<originalTail.endIndex, in: originalTail)
        let matches = regex.matches(in: originalTail, options: [], range: range)
        
        var results: [String] = []
        for match in matches {
            guard let matchRange = Range(match.range, in: originalTail) else { continue }
            let candidate = originalTail[matchRange].trimmingCharacters(in: .whitespaces)
            if candidate.count >= 6 {
                results.append(candidate)
            }
        }
        
        return results
    }
    
    private func dedupe(_ questions: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for question in questions {
            let key = question.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                result.append(question)
            }
        }
        return result
    }
    
    func detectFromAudio(_ audioText: String) -> [String] {
        return detectQuestions(in: audioText)
    }
    
    func detectFromScreen(_ screenText: String) -> [String] {
        return detectQuestions(in: screenText)
    }
}

