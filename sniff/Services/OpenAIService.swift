//
//  OpenAIService.swift
//  sniff
//

import Foundation

class OpenAIService: LLMService {
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func streamAnswer(
        _ question: String,
        screenContext: String? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        var systemPrompt = "You are a helpful assistant. Answer questions concisely and accurately using Markdown formatting. Use code blocks with language specifiers for code, bullet points for lists, and keep responses brief."
        if let context = screenContext, !context.isEmpty {
            systemPrompt += " Here is the current screen context: \(context)"
        }

        let requestBody: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": question]
            ],
            "max_tokens": 1024,
            "temperature": 0.2,
            "stream": true
        ]

        guard let url = URL(string: baseURL) else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw LLMError.serializationFailed
        }
        request.httpBody = httpBody

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        var collected = ""

        for try await line in bytes.lines {
            guard let delta = Self.parseStreamLine(line) else { continue }
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

    func streamAnswerWithImage(
        prompt: String,
        imageData: Data,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let base64Image = imageData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64Image)"
        
        let requestBody: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]
                ]
            ],
            "max_tokens": 1024,
            "temperature": 0.2,
            "stream": true
        ]
        
        guard let url = URL(string: baseURL) else {
            throw LLMError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw LLMError.serializationFailed
        }
        request.httpBody = httpBody
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw LLMError.httpError(httpResponse.statusCode)
        }
        
        var collected = ""
        
        for try await line in bytes.lines {
            guard let delta = Self.parseStreamLine(line) else { continue }
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

    private static func parseStreamLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return "[DONE]"
        }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }

        return content
    }
}
