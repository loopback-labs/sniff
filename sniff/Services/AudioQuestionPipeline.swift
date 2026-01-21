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
    private var lastProcessedQuestions: Set<String> = []
    
    init(questionDetectionService: QuestionDetectionService) {
        self.questionDetectionService = questionDetectionService
    }
    
    func process(transcribedText: String) -> (latestQuestion: String?, questions: [String]) {
        guard !transcribedText.isEmpty else {
            return (nil, [])
        }
        
        // Use the full detection service which handles both punctuated and unpunctuated text
        let allQuestions = questionDetectionService.detectQuestions(in: transcribedText)
        
        // Find only new questions (not previously processed)
        let newQuestions = allQuestions.filter { !lastProcessedQuestions.contains($0.lowercased()) }
        
        // Update processed set
        for q in allQuestions {
            lastProcessedQuestions.insert(q.lowercased())
        }
        
        // Limit memory - keep only recent questions
        if lastProcessedQuestions.count > 50 {
            lastProcessedQuestions.removeAll()
            for q in allQuestions.suffix(10) {
                lastProcessedQuestions.insert(q.lowercased())
            }
        }
        
        // Return the latest question from the full text (for highlighting)
        // and only new questions for auto-processing
        return (allQuestions.last, newQuestions)
    }
    
    func reset() {
        lastProcessedQuestions.removeAll()
    }
}
