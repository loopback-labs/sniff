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
        
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemPrompt
            ],
            [
                "role": "user",
                "content": question
            ]
        ]
        
        let requestBody: [String: Any] = [
            "model": "sonar",
            "messages": messages,
            "max_tokens": 1024,
            "temperature": 0.2,
            "stream": false
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

    func streamAnswer(
        _ question: String,
        screenContext: String? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        var systemPrompt = "You are a helpful assistant that answers questions concisely and accurately."
        if let context = screenContext, !context.isEmpty {
            systemPrompt += " Here is the current screen context: \(context)"
        }

        let requestBody: [String: Any] = [
            "model": "sonar",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": question]
            ],
            "max_tokens": 1024,
            "temperature": 0.2,
            "stream": true
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

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PerplexityError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PerplexityError.httpError(httpResponse.statusCode)
        }

        var collected = ""

        for try await line in bytes.lines {
            guard let delta = PerplexityService.parseStreamLine(line) else { continue }
            if delta == "[DONE]" {
                break
            }
            if !delta.isEmpty {
                collected += delta
                onChunk(delta)
            }
        }

        return collected
    }

    static func parseStreamLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return "[DONE]"
        }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            return nil
        }

        if let delta = firstChoice["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }

        if let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        return nil
    }
}

enum PerplexityError: Error {
    case invalidURL
    case serializationFailed
    case invalidResponse
    case httpError(Int)
    case apiError(String)
}
