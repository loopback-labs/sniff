//
//  PerplexityService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

class PerplexityService {
    private let apiKey: String
    private let baseURL = "https://api.perplexity.ai/chat/completions"
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func answerQuestion(_ question: String, screenContext: String? = nil) async throws -> String {
        var systemPrompt = "You are a helpful assistant that answers questions concisely and accurately."
        if let context = screenContext, !context.isEmpty {
            systemPrompt += " Here is the current screen context: \(context)"
        }
        
        var messages: [[String: Any]] = []
        
        // Add system message if context exists
        if let context = screenContext, !context.isEmpty {
            messages.append([
                "role": "system",
                "content": systemPrompt
            ])
        }
        
        // Add user message with question
        var userContent = question
        if let context = screenContext, !context.isEmpty {
            userContent = "Screen context: \(context)\n\nQuestion: \(question)"
        }
        
        messages.append([
            "role": "user",
            "content": userContent
        ])
        
        let requestBody: [String: Any] = [
            "model": "llama-3.1-sonar-small-128k-online",
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.2
        ]
        
        guard let url = URL(string: baseURL) else {
            throw PerplexityError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw PerplexityError.serializationFailed
        }
        request.httpBody = httpBody
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PerplexityError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorData["error"] as? [String: Any],
               let message = errorMessage["message"] as? String {
                throw PerplexityError.apiError(message)
            }
            throw PerplexityError.httpError(httpResponse.statusCode)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw PerplexityError.invalidResponse
        }
        
        return content
    }
}

enum PerplexityError: Error {
    case invalidURL
    case serializationFailed
    case invalidResponse
    case httpError(Int)
    case apiError(String)
}
