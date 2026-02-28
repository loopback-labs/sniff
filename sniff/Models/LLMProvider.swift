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
    
    func streamAnswerWithImage(
        prompt: String,
        imageData: Data,
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

extension LLMError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API endpoint URL."
        case .serializationFailed: return "Failed to serialize request."
        case .invalidResponse: return "Invalid response from server."
        case .httpError(let code): return "HTTP \(code).\(code == 401 ? " Check your API key in Settings." : "")"
        case .apiError(let message): return message
        }
    }
}
