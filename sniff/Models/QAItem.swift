//
//  QAItem.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

struct QAItem: Identifiable, Equatable {
    let id: UUID
    let question: String
    var answer: String?
    let source: QuestionSource
    let timestamp: Date
    let screenContext: String?
    
    init(question: String, source: QuestionSource, screenContext: String? = nil) {
        self.id = UUID()
        self.question = question
        self.answer = nil
        self.source = source
        self.timestamp = Date()
        self.screenContext = screenContext
    }
    
    static func == (lhs: QAItem, rhs: QAItem) -> Bool {
        lhs.id == rhs.id
    }
}
