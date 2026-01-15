//
//  QAManager.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Combine

@MainActor
class QAManager: ObservableObject {
    @Published var items: [QAItem] = []
    @Published var currentIndex: Int = -1
    
    var currentItem: QAItem? {
        guard currentIndex >= 0 && currentIndex < items.count else {
            return nil
        }
        return items[currentIndex]
    }
    
    var canGoPrevious: Bool {
        currentIndex > 0
    }
    
    var canGoNext: Bool {
        currentIndex < items.count - 1
    }
    
    func addQuestion(_ question: String, source: QuestionSource, screenContext: String? = nil) -> QAItem {
        let item = QAItem(question: question, source: source, screenContext: screenContext)
        items.append(item)
        currentIndex = items.count - 1
        return item
    }
    
    func updateAnswer(for itemId: UUID, answer: String) {
        if let index = items.firstIndex(where: { $0.id == itemId }) {
            items[index].answer = answer
        }
    }
    
    func goToPrevious() {
        guard canGoPrevious else { return }
        currentIndex -= 1
    }
    
    func goToNext() {
        guard canGoNext else { return }
        currentIndex += 1
    }
    
    func goToFirst() {
        guard !items.isEmpty else { return }
        currentIndex = 0
    }
    
    func goToLast() {
        guard !items.isEmpty else { return }
        currentIndex = items.count - 1
    }
    
    func clear() {
        items.removeAll()
        currentIndex = -1
    }
}
