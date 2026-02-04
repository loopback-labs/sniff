//
//  AudioQuestionPipeline.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

@MainActor
class AudioQuestionPipeline {
    private enum Constants {
        static let maxProcessedQuestions = 50
        static let retainedTailCount = 10
    }

    private let questionDetectionService: QuestionDetectionService
    private var lastProcessedQuestions: Set<String> = []
    
    init(questionDetectionService: QuestionDetectionService) {
        self.questionDetectionService = questionDetectionService
    }
    
    func process(recentText: String) -> (latestQuestion: String?, questions: [String]) {
        guard !recentText.isEmpty else {
            return (nil, [])
        }
        
        // Use the full detection service which handles both punctuated and unpunctuated text
        let allQuestions = questionDetectionService.detectQuestions(in: recentText)
        let normalizedQuestions = allQuestions.map { questionDetectionService.normalizedKey($0) }
        
        // Find only new questions (not previously processed)
        let newQuestions = zip(allQuestions, normalizedQuestions).compactMap { question, normalized in
            lastProcessedQuestions.contains(normalized) ? nil : question
        }
        
        // Update processed set
        lastProcessedQuestions.formUnion(normalizedQuestions)
        
        // Limit memory - keep only recent questions
        if lastProcessedQuestions.count > Constants.maxProcessedQuestions {
            lastProcessedQuestions = Set(normalizedQuestions.suffix(Constants.retainedTailCount))
        }
        
        // Return the latest question from the full text (for highlighting)
        // and only new questions for auto-processing
        return (allQuestions.last, newQuestions)
    }
    
    func reset() {
        lastProcessedQuestions.removeAll()
    }
}
