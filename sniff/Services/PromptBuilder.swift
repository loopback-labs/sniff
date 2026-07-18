//
//  PromptBuilder.swift
//  sniff
//

import Foundation

struct PromptPayload {
  let systemPrompt: String
  let userMessage: String
  let options: LLMRequestOptions
}

@MainActor
struct PromptBuilder {
  private let qaHistoryCharBudget = 300
  private let qaAnswerCharBudget = 600
  private let qaHistorySectionBudget = 3000
  private let qaHistoryMaxItems = 3

  func build(
    mode: PromptMode,
    transcript: TranscriptBuffer,
    qaHistory: [QAItem],
    detectedQuestion: String? = nil,
    typedText: String? = nil
  ) -> PromptPayload {
    var sections: [String] = []

    if mode.transcriptCharBudget > 0 {
      let transcriptText = transcriptSection(for: mode, transcript: transcript)
      let header = mode == .recap ? "Full transcript:" : "Recent conversation:"
      let body = transcriptText.isEmpty ? emptyTranscriptPlaceholder(for: mode) : transcriptText
      sections.append("\(header)\n\(body)")
    }

    if mode.includesQAHistory {
      let qaSection = formatQAHistory(qaHistory)
      if !qaSection.isEmpty {
        sections.append("Earlier in this session you already answered:\n\(qaSection)")
      }
    }

    sections.append(closingLine(for: mode, detectedQuestion: detectedQuestion, typedText: typedText))

    let userMessage = sections.joined(separator: "\n\n")
    return PromptPayload(systemPrompt: mode.systemPrompt, userMessage: userMessage, options: mode.options)
  }

  private func transcriptSection(for mode: PromptMode, transcript: TranscriptBuffer) -> String {
    if mode == .recap, let fullTranscript = transcript.fullSessionTranscript(maxCharacters: mode.transcriptCharBudget) {
      return fullTranscript
    }
    return formatTranscript(transcript.recentTurns(), charBudget: mode.transcriptCharBudget)
  }

  private func emptyTranscriptPlaceholder(for mode: PromptMode) -> String {
    switch mode {
    case .answerQuestion: return "(no recent conversation captured)"
    case .sayNext: return "(nothing heard yet)"
    case .followUps: return "(none)"
    case .recap: return "(nothing captured yet)"
    case .ask: return "(none)"
    case .solveScreen: return ""
    }
  }

  private func closingLine(for mode: PromptMode, detectedQuestion: String?, typedText: String?) -> String {
    switch mode {
    case .answerQuestion:
      return "Question asked on the call: \(detectedQuestion ?? "").\n\nAnswer it."
    case .solveScreen:
      return "Solve the coding problem shown in the screenshot."
    case .sayNext:
      return "What should I say next?"
    case .followUps:
      return "Suggest follow-up questions."
    case .recap:
      return "Recap this."
    case .ask:
      return "Question: \(typedText ?? "")"
    }
  }

  // MARK: - Transcript formatting

  private func mergeConsecutiveTurns(
    _ turns: [(speaker: TranscriptSpeaker, text: String)]
  ) -> [(speaker: TranscriptSpeaker, text: String)] {
    var merged: [(speaker: TranscriptSpeaker, text: String)] = []
    for turn in turns {
      if !merged.isEmpty, merged[merged.count - 1].speaker == turn.speaker {
        merged[merged.count - 1].text += " " + turn.text
      } else {
        merged.append(turn)
      }
    }
    return merged
  }

  private func formatTranscript(_ turns: [(speaker: TranscriptSpeaker, text: String)], charBudget: Int) -> String {
    guard charBudget > 0, !turns.isEmpty else { return "" }
    let merged = mergeConsecutiveTurns(turns)

    var lines: [String] = []
    var length = 0
    for turn in merged.reversed() {
      let label = turn.speaker == .you ? "You: " : "Them: "

      if lines.isEmpty, label.count + turn.text.count > charBudget {
        // A single (possibly merged) turn alone overflows the budget: keep its most recent tail.
        let keepChars = max(0, charBudget - label.count - 1)
        let text = turn.text.count > keepChars ? "…" + String(turn.text.suffix(keepChars)) : turn.text
        lines.append(label + text)
        break
      }

      let line = label + turn.text
      let added = line.count + (lines.isEmpty ? 0 : 1)
      if !lines.isEmpty && length + added > charBudget { break }
      lines.append(line)
      length += added
    }
    return lines.reversed().joined(separator: "\n")
  }

  // MARK: - Q&A history formatting

  private func formatQAHistory(_ items: [QAItem]) -> String {
    let candidates = items.filter { item in
      guard let answer = item.answer, !answer.isEmpty, !answer.hasPrefix("Error:") else { return false }
      return true
    }
    guard !candidates.isEmpty else { return "" }

    let entries = candidates.map { item -> String in
      let question = truncateHead(item.question, limit: qaHistoryCharBudget)
      let answer = truncateTail(item.answer ?? "", limit: qaAnswerCharBudget)
      return "Q: \(question)\nA: \(answer)"
    }
    return TranscriptionTextUtils.joinTailWithinBudget(entries, charBudget: qaHistorySectionBudget, maxItems: qaHistoryMaxItems)
  }

  private func truncateHead(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "…"
  }

  private func truncateTail(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return "…" + String(text.suffix(limit))
  }
}
