//
//  TranscriptBuffer.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Combine

@MainActor
final class TranscriptBuffer: ObservableObject {
    @Published private(set) var displayText: String = ""

    private var lastFullText: String = ""
    private let maxLines: Int
    private let maxLineLength: Int

    init(maxLines: Int = 6, maxLineLength: Int = 60) {
        self.maxLines = maxLines
        self.maxLineLength = maxLineLength
    }

    func update(with fullText: String) {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            displayText = ""
            lastFullText = ""
            return
        }

        lastFullText = fullText
        displayText = renderTail(from: trimmed)
    }
    
    func clear() {
        displayText = ""
        lastFullText = ""
    }

    private func renderTail(from text: String) -> String {
        let lines = wrap(text: text)
        let tail = lines.suffix(maxLines)
        return tail.joined(separator: "\n")
    }

    private func wrap(text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var lines: [String] = []
        var current = ""

        for wordSub in words {
            let word = String(wordSub)
            if current.isEmpty {
                current = word
                continue
            }

            if current.count + 1 + word.count <= maxLineLength {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines
    }
}
