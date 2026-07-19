//
//  LLMModelCatalog.swift
//  sniff
//

import Foundation

struct LLMModelOption: Identifiable, Hashable {
  let id: String
  let displayName: String
  let supportsVision: Bool

  init(id: String, displayName: String? = nil, supportsVision: Bool) {
    self.id = id
    self.displayName = displayName ?? id
    self.supportsVision = supportsVision
  }
}

enum LLMModelCatalog {
  private static let openAIModelOptions: [LLMModelOption] = [
    // source: https://platform.openai.com/docs/models
    LLMModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", supportsVision: true),
    LLMModelOption(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", supportsVision: true),
    LLMModelOption(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", supportsVision: true),
  ]

  private static let chatgptModelIds: Set<String> = [
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
  ]

  static func models(for provider: LLMProvider) -> [LLMModelOption] {
    switch provider {
    case .openai:
      return openAIModelOptions
    case .chatgpt:
      return openAIModelOptions.filter { chatgptModelIds.contains($0.id) }
    case .claude:
      return [
        // source: https://platform.claude.com/docs/en/about-claude/models/overview
        LLMModelOption(id: "claude-sonnet-5", displayName: "Sonnet 5", supportsVision: true),
        LLMModelOption(id: "claude-opus-4-8", displayName: "Opus 4.8", supportsVision: true),
        LLMModelOption(id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", supportsVision: true),
        LLMModelOption(id: "claude-fable-5", displayName: "Fable 5", supportsVision: true),
      ]
    case .gemini:
      return [
        // Source: https://ai.google.dev/gemini-api/docs/pricing
        LLMModelOption(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", supportsVision: true),
        LLMModelOption(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsVision: true),
        LLMModelOption(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite", supportsVision: true),
        LLMModelOption(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro Preview", supportsVision: true),
      ]
    }
  }

  static func defaultModelId(for provider: LLMProvider) -> String {
    models(for: provider).first?.id ?? openAIModelOptions.first?.id ?? "gpt-5.6-luna"
  }

  static func supportsVision(provider: LLMProvider, modelId: String) -> Bool {
    models(for: provider).first(where: { $0.id == modelId })?.supportsVision ?? false
  }

  static func isValidModelId(_ modelId: String, for provider: LLMProvider) -> Bool {
    models(for: provider).contains(where: { $0.id == modelId })
  }

  static func storageKey(for provider: LLMProvider) -> String {
    UserDefaultsKeys.llmModelId(for: provider)
  }

  static func savedModelId(for provider: LLMProvider) -> String? {
    UserDefaults.standard.string(forKey: UserDefaultsKeys.llmModelId(for: provider))
  }

  static func loadOrDefaultModelId(for provider: LLMProvider) -> String {
    if let saved = savedModelId(for: provider), isValidModelId(saved, for: provider) {
      return saved
    }
    return defaultModelId(for: provider)
  }

  static func saveModelId(_ modelId: String, for provider: LLMProvider) {
    UserDefaults.standard.set(modelId, forKey: UserDefaultsKeys.llmModelId(for: provider))
  }
}
