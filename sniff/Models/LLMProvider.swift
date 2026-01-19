//
//  LLMProvider.swift
//  sniff
//

import Foundation

enum LLMProvider: String, CaseIterable, Identifiable {
    case openai = "openai"
    case claude = "claude"
    case gemini = "gemini"
    case perplexity = "perplexity"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .perplexity: return "Perplexity"
        }
    }
    
    var keychainKey: String {
        return "\(rawValue)_api_key"
    }
}

protocol LLMService {
    func streamAnswer(
        _ question: String,
        screenContext: String?,
        onChunk: @escaping (String) -> Void
    ) async throws -> String
}

enum LLMError: Error {
    case invalidURL
    case serializationFailed
    case invalidResponse
    case httpError(Int)
    case apiError(String)
}
