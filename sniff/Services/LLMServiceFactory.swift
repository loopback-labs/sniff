//
//  LLMServiceFactory.swift
//  sniff
//

import Foundation

enum LLMServiceFactory {
  static func makeService(
    provider: LLMProvider,
    modelId: String,
    keychain: KeychainService,
    chatGPTAuth: ChatGPTAuthManager
  ) -> LLMService? {
    switch provider {
    case .chatgpt:
      guard chatGPTAuth.isSignedIn else { return nil }
      return ChatGPTService(model: modelId, authManager: chatGPTAuth)
    case .openai:
      guard let apiKey = keychain.getAPIKey(for: .openai), !apiKey.isEmpty else { return nil }
      return OpenAIService(apiKey: apiKey, model: modelId)
    case .claude:
      guard let apiKey = keychain.getAPIKey(for: .claude), !apiKey.isEmpty else { return nil }
      return ClaudeService(apiKey: apiKey, model: modelId)
    case .gemini:
      guard let apiKey = keychain.getAPIKey(for: .gemini), !apiKey.isEmpty else { return nil }
      return GeminiService(apiKey: apiKey, model: modelId)
    }
  }
}
