import Foundation


struct LLMModelOption: Identifiable, Hashable {
  let id: String
  let displayName: String
  let supportsVision: Bool
  /// Whether the model accepts a thinking/reasoning-effort parameter. Legacy reasoning models that
  /// only take a fixed token budget count as false — the budget floor (1024) exceeds the token cap
  /// of the shortest prompt modes, so there is nothing sensible to send.
  let supportsThinkingLevel: Bool

  init(
    id: String,
    displayName: String? = nil,
    supportsVision: Bool,
    supportsThinkingLevel: Bool = true
  ) {
    self.id = id
    self.displayName = displayName ?? id
    self.supportsVision = supportsVision
    self.supportsThinkingLevel = supportsThinkingLevel
  }
}

enum LLMModelCatalog {
  private static let openAIModelOptions: [LLMModelOption] = [
    // source: https://platform.openai.com/docs/models
    LLMModelOption(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", supportsVision: true),
    LLMModelOption(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", supportsVision: true),
    LLMModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", supportsVision: true),
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
        LLMModelOption(
          id: "claude-haiku-4-5",
          displayName: "Haiku 4.5",
          supportsVision: true,
          supportsThinkingLevel: false
        ),
        LLMModelOption(id: "claude-opus-5", displayName: "Opus 5", supportsVision: true),
      ]
    case .gemini:
      return [
        // Source: https://ai.google.dev/gemini-api/docs/models
        LLMModelOption(id: "gemini-3.5-flash-lite", displayName: "Gemini 3.5 Flash-Lite", supportsVision: true),
        LLMModelOption(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite", supportsVision: true),
        LLMModelOption(id: "gemini-3.7-flash", displayName: "Gemini 3.7 Flash", supportsVision: true),
        LLMModelOption(id: "gemini-3.6-flash", displayName: "Gemini 3.6 Flash", supportsVision: true),
      ]
    }
  }

  static func defaultModelId(for provider: LLMProvider) -> String {
    models(for: provider).first?.id ?? openAIModelOptions.first?.id ?? "gpt-5.6-luna"
  }

  /// Falls back to the provider's default rather than returning nil so callers never have to decide
  /// what an unrecognized model id means — the caller already resolved it through this catalog.
  static func option(provider: LLMProvider, modelId: String) -> LLMModelOption {
    let options = models(for: provider)
    return options.first(where: { $0.id == modelId })
      ?? options.first
      ?? LLMModelOption(id: modelId, supportsVision: false, supportsThinkingLevel: false)
  }

  static func supportsVision(provider: LLMProvider, modelId: String) -> Bool {
    option(provider: provider, modelId: modelId).supportsVision
  }

  static func isValidModelId(_ modelId: String, for provider: LLMProvider) -> Bool {
    models(for: provider).contains(where: { $0.id == modelId })
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
