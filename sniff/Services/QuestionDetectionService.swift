//
//  QuestionDetectionService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

class QuestionDetectionService {
    let questionWords = ["what", "who", "when", "where", "why", "how", "which", "whose", "whom"]
    private let questionVerbs = ["is", "are", "was", "were", "do", "does", "did", "can", "could", "will", "would", "should", "may", "might"]
    
    func detectQuestions(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        
        let sentences = splitIntoSentences(text)
        var questions: [String] = []
        
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            if isQuestion(trimmed) {
                questions.append(trimmed)
            }
        }

        // Only use fallback if text has no sentence-ending punctuation at all
        // (indicates incomplete/streaming transcription)
        let hasPunctuation = text.contains(where: { $0 == "." || $0 == "?" || $0 == "!" })
        if questions.isEmpty && !hasPunctuation {
            let fallbackQuestions = detectQuestionsWithoutPunctuation(in: text)
            questions.append(contentsOf: fallbackQuestions)
        }
        
        return dedupe(questions)
    }
    
    func splitIntoSentences(_ text: String) -> [String] {
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
        
        let leftover = remaining.trimmingCharacters(in: .whitespaces)
        if !leftover.isEmpty {
            sentences.append(leftover)
        }
        
        return sentences
    }
    
    func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        
        if trimmed.hasSuffix("?") {
            return true
        }
        
        let lowercased = trimmed.lowercased()
        for word in questionWords {
            if lowercased.hasPrefix("\(word) ") || lowercased == word {
                return true
            }
        }
        
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
}

