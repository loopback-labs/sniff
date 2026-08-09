import Foundation


struct QAItem: Identifiable, Equatable {
    let id: UUID
    let question: String
    var answer: String?
    let source: QuestionSource
    let timestamp: Date

    init(question: String, source: QuestionSource) {
        self.id = UUID()
        self.question = question
        self.answer = nil
        self.source = source
        self.timestamp = Date()
    }
}
