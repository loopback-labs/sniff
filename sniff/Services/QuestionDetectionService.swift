//
//  QuestionDetectionService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

class QuestionDetectionService {
    private enum Constants {
        static let questionWords = ["what", "who", "when", "where", "why", "how", "which", "whose", "whom", "explain", "describe", "tell"]
        static let questionVerbs = ["is", "are", "was", "were", "do", "does", "did", "can", "could", "will", "would", "should", "may", "might", "me"]
        static let questionTokens = questionWords + questionVerbs
        static let wordGroup = questionTokens.joined(separator: "|")
        static let noPunctuationRegex = try? NSRegularExpression(
            pattern: "\\b(\(wordGroup))\\b[^.?!\\n]*",
            options: [.caseInsensitive]
        )
        static let sentencePunctuation: Set<Character> = [".", "?", "!"]
    }
    
    func detectQuestions(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        let sentences = splitIntoSentences(trimmed)
        var questions = sentences.compactMap { sentence -> String? in
            let sentenceTrimmed = sentence.trimmingCharacters(in: .whitespaces)
            return isQuestion(sentenceTrimmed) ? sentenceTrimmed : nil
        }

        // Only use fallback if text has no sentence-ending punctuation at all
        // (indicates incomplete/streaming transcription)
        let hasPunctuation = containsSentencePunctuation(in: trimmed)
        if questions.isEmpty && !hasPunctuation {
            questions = detectQuestionsWithoutPunctuation(in: trimmed)
        }
        
        return dedupe(questions)
    }

    func firstQuestion(in text: String) -> String? {
        detectQuestions(in: text).first
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
        if hasLeadingToken(in: lowercased, tokens: Constants.questionWords, allowExactMatch: true) {
            return true
        }
        
        return hasLeadingToken(in: lowercased, tokens: Constants.questionVerbs, allowExactMatch: false)
    }
    
    private func detectQuestionsWithoutPunctuation(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        let lowercased = trimmed.lowercased()
        let maxTailLength = 400
        let tail = lowercased.suffix(maxTailLength)
        let startIndex = lowercased.index(lowercased.endIndex, offsetBy: -tail.count)
        let originalTail = String(trimmed[startIndex...])
        
        guard let regex = Constants.noPunctuationRegex else { return [] }
        
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
            let key = normalizedKey(question)
            if !seen.contains(key) {
                seen.insert(key)
                result.append(question)
            }
        }
        return result
    }

    func normalizedKey(_ question: String) -> String {
        question.lowercased()
    }

    private func hasLeadingToken(in text: String, tokens: [String], allowExactMatch: Bool) -> Bool {
        for token in tokens {
            if text.hasPrefix("\(token) ") {
                return true
            }
            if allowExactMatch && text == token {
                return true
            }
        }
        return false
    }

    private func containsSentencePunctuation(in text: String) -> Bool {
        text.contains { Constants.sentencePunctuation.contains($0) }
    }
}
