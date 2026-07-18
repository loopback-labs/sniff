//
//  PromptMode.swift
//  sniff
//

import Foundation

struct LLMRequestOptions {
  let maxTokens: Int
  let temperature: Double?
}

enum PromptMode: CaseIterable {
  case answerQuestion
  case solveScreen
  case sayNext
  case followUps
  case recap
  case ask

  private static let personaPreamble =
    "You are sniff, a discreet real-time copilot overlaid on the user's screen during a live call. " +
    "In transcripts, 'You:' lines are the user speaking and 'Them:' lines are other people on the call. " +
    "Respond in Markdown with no preamble. Never mention the transcript, the screenshot, or that you are an AI overlay."

  var systemPrompt: String {
    "\(Self.personaPreamble) \(instruction)"
  }

  private var instruction: String {
    switch self {
    case .answerQuestion:
      return "A question was just asked on the call. Answer it directly and concisely for the user to relay. " +
        "Use the recent conversation to resolve pronouns and context. Use fenced code blocks for code, " +
        "bullet points for lists, and keep the answer brief."
    case .solveScreen:
      return "The screenshot contains a coding problem. Respond with: (1) a one-line restatement, " +
        "(2) a short approach, (3) a clean, correct, idiomatic solution in a fenced code block " +
        "(use the language shown on screen, else Python), (4) time and space complexity."
    case .sayNext:
      return "Draft ONE short, natural, confident reply the user can say out loud, in the first person. " +
        "No quotes, no preamble, 1-3 sentences."
    case .followUps:
      return "Suggest 2-4 sharp, relevant follow-up questions the user could ask next to sound engaged " +
        "and drive the discussion. Return them as a short bullet list, nothing else."
    case .recap:
      return "Summarize the conversation so far for someone who joined late: a few key points, any decisions, " +
        "and action items. Use short bullets under bold headers. Be brief."
    case .ask:
      return "Answer the user's question directly and concisely, grounded in what is on screen and what was said."
    }
  }

  var displayBubble: String? {
    switch self {
    case .answerQuestion, .ask: return nil
    case .solveScreen: return "Solve what's on screen"
    case .sayNext: return "What should I say?"
    case .followUps: return "Follow-up questions"
    case .recap: return "Recap"
    }
  }

  var transcriptCharBudget: Int {
    switch self {
    case .answerQuestion, .ask, .sayNext: return 4000
    case .followUps: return 6000
    case .recap: return 20000
    case .solveScreen: return 0
    }
  }

  var includesQAHistory: Bool {
    switch self {
    case .answerQuestion, .ask: return true
    case .solveScreen, .sayNext, .followUps, .recap: return false
    }
  }

  /// The QAItem source tag recorded for items produced by this mode.
  var questionSource: QuestionSource {
    switch self {
    case .answerQuestion: return .manual
    case .solveScreen: return .screen
    case .sayNext: return .sayNext
    case .followUps: return .followUps
    case .recap: return .recap
    case .ask: return .typed
    }
  }

  enum ImageCaptureRequirement {
    case none
    case required
    case whenVisionSupported
  }

  var imageCapture: ImageCaptureRequirement {
    switch self {
    case .solveScreen: return .required
    case .ask: return .whenVisionSupported
    case .answerQuestion, .sayNext, .followUps, .recap: return .none
    }
  }

  var options: LLMRequestOptions {
    switch self {
    case .answerQuestion, .ask:
      return LLMRequestOptions(maxTokens: 2048, temperature: 0.2)
    case .solveScreen:
      return LLMRequestOptions(maxTokens: 4096, temperature: 0.2)
    case .sayNext, .followUps:
      return LLMRequestOptions(maxTokens: 512, temperature: 0.7)
    case .recap:
      return LLMRequestOptions(maxTokens: 1024, temperature: 0.3)
    }
  }
}
