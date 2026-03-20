//
//  LLMModelCatalog.swift
//  sniff
//

import Foundation

/// Curated model options per provider. `supportsVision` controls screen-question (image) flows.
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
  private static let storagePrefix = "llmModelId_"

  static func models(for provider: LLMProvider) -> [LLMModelOption] {
    switch provider {
    case .openai:
      return [
        LLMModelOption(id: "gpt-4o", supportsVision: true),
        LLMModelOption(id: "gpt-4o-mini", supportsVision: true),
        LLMModelOption(id: "gpt-4.1", supportsVision: true),
        LLMModelOption(id: "gpt-4.1-mini", supportsVision: true),
        LLMModelOption(id: "o4-mini", supportsVision: false),
        LLMModelOption(id: "o3-mini", supportsVision: false),
        LLMModelOption(id: "gpt-4-turbo", supportsVision: true)
      ]
    case .claude:
      return [
        LLMModelOption(id: "claude-sonnet-4-20250514", supportsVision: true),
        LLMModelOption(id: "claude-3-5-sonnet-20241022", supportsVision: true),
        LLMModelOption(id: "claude-3-5-haiku-20241022", supportsVision: true),
        LLMModelOption(id: "claude-3-opus-20240229", supportsVision: true)
      ]
    case .gemini:
      return [
        LLMModelOption(id: "gemini-3-flash-preview", supportsVision: true),
        LLMModelOption(id: "gemini-2.5-flash", supportsVision: true),
        LLMModelOption(id: "gemini-2.5-pro", supportsVision: true),
        LLMModelOption(id: "gemini-2.0-flash", supportsVision: true)
      ]
    case .chatgpt:
      return [
        LLMModelOption(id: "gpt-4o", supportsVision: true),
        LLMModelOption(id: "gpt-4.1", supportsVision: true),
        LLMModelOption(id: "gpt-4.1-mini", supportsVision: true),
        LLMModelOption(id: "o4-mini", supportsVision: false),
        LLMModelOption(id: "o3-mini", supportsVision: false)
      ]
    }
  }

  static func defaultModelId(for provider: LLMProvider) -> String {
    models(for: provider).first?.id ?? "gpt-4o"
  }

  static func supportsVision(provider: LLMProvider, modelId: String) -> Bool {
    models(for: provider).first(where: { $0.id == modelId })?.supportsVision ?? false
  }

  static func isValidModelId(_ modelId: String, for provider: LLMProvider) -> Bool {
    models(for: provider).contains(where: { $0.id == modelId })
  }

  static func storageKey(for provider: LLMProvider) -> String {
    "\(storagePrefix)\(provider.rawValue)"
  }

  static func savedModelId(for provider: LLMProvider) -> String? {
    UserDefaults.standard.string(forKey: storageKey(for: provider))
  }

  static func loadOrDefaultModelId(for provider: LLMProvider) -> String {
    if let saved = savedModelId(for: provider), isValidModelId(saved, for: provider) {
      return saved
    }
    return defaultModelId(for: provider)
  }

  static func saveModelId(_ modelId: String, for provider: LLMProvider) {
    UserDefaults.standard.set(modelId, forKey: storageKey(for: provider))
  }
}
