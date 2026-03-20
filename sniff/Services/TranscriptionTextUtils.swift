//
//  TranscriptionTextUtils.swift
//  sniff
//

import Foundation

enum TranscriptionTextUtils {
  static func rootMeanSquare(of samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for x in samples {
      sum += x * x
    }
    return sqrt(sum / Float(samples.count))
  }

  static func appendWithBoundarySmoothing(_ existing: String, _ addition: String) -> String {
    guard !addition.isEmpty else { return existing }
    guard !existing.isEmpty else { return addition }

    let maxSuffixChars = 48
    let suffix = String(existing.suffix(maxSuffixChars))
    if addition.hasPrefix(suffix) {
      let trimmed = String(addition.dropFirst(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return existing }
      return existing + " " + trimmed
    }

    if existing.last?.isWhitespace == true {
      return existing + addition
    }
    return existing + " " + addition
  }

  static func normalizeSystemText(_ rawText: String) -> String {
    var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let last = text.last, !".!?".contains(last) {
      text.append(".")
    }
    return text
  }
}
