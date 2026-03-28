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

        let allQuestions = questionDetectionService.detectQuestions(in: recentText)
        let normalizedQuestions = allQuestions.map { questionDetectionService.normalizedKey($0) }

        let newQuestions = zip(allQuestions, normalizedQuestions).compactMap { question, normalized in
            lastProcessedQuestions.contains(normalized) ? nil : question
        }

        lastProcessedQuestions.formUnion(normalizedQuestions)

        if lastProcessedQuestions.count > Constants.maxProcessedQuestions {
            lastProcessedQuestions = Set(normalizedQuestions.suffix(Constants.retainedTailCount))
        }

        return (allQuestions.last, newQuestions)
    }
    
    func reset() {
        lastProcessedQuestions.removeAll()
    }
}
