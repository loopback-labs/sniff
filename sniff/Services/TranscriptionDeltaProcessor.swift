//
//  TranscriptionDeltaProcessor.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

final class TranscriptionDeltaProcessor {
    private var lastText: String = ""

    func consume(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastText = ""
            return ""
        }

        if lastText.isEmpty {
            lastText = text
            return trimmed
        }

        if text.count < lastText.count {
            lastText = text
            return trimmed
        }

        let prefixLength = commonPrefixLength(text, lastText)
        let deltaIndex = text.index(text.startIndex, offsetBy: prefixLength)
        let delta = text[deltaIndex...].trimmingCharacters(in: .whitespacesAndNewlines)

        lastText = text
        return String(delta)
    }

    func reset() {
        lastText = ""
    }

    private func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        let minCount = min(lhs.count, rhs.count)
        var count = 0
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex

        while count < minCount {
            if lhs[lhsIndex] != rhs[rhsIndex] {
                break
            }
            count += 1
            lhsIndex = lhs.index(after: lhsIndex)
            rhsIndex = rhs.index(after: rhsIndex)
        }
        return count
    }
}
