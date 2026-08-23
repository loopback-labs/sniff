import Foundation


enum LLMServiceFactory {
  @MainActor static func makeService(
    provider: LLMProvider,
    modelId: String,
    thinkingLevel: ThinkingLevel,
    keychain: KeychainService,
    chatGPTAuth: ChatGPTAuthManager
  ) -> LLMService? {
    let model = LLMModelCatalog.option(provider: provider, modelId: modelId)
    switch provider {
    case .chatgpt:
      guard chatGPTAuth.isSignedIn else { return nil }
      return ChatGPTService(model: model, thinkingLevel: thinkingLevel, authManager: chatGPTAuth)
    case .openai:
      guard let apiKey = keychain.getAPIKey(for: .openai), !apiKey.isEmpty else { return nil }
      return OpenAIService(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
    case .claude:
      guard let apiKey = keychain.getAPIKey(for: .claude), !apiKey.isEmpty else { return nil }
      return ClaudeService(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
    case .gemini:
      guard let apiKey = keychain.getAPIKey(for: .gemini), !apiKey.isEmpty else { return nil }
      return GeminiService(apiKey: apiKey, model: model, thinkingLevel: thinkingLevel)
    }
  }
}
