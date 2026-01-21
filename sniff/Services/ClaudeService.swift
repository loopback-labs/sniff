//
//  ClaudeService.swift
//  sniff
//

import Foundation

class ClaudeService: LLMService {
    private let apiKey: String
    private let baseURL = "https://api.anthropic.com/v1/messages"
    
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
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": question]
            ],
            "stream": true
        ]

        guard let url = URL(string: baseURL) else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

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
        
        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        ["type": "text", "text": prompt]
                    ]
                ]
            ],
            "stream": true
        ]
        
        guard let url = URL(string: baseURL) else {
            throw LLMError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
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
        
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Claude uses content_block_delta for streaming
        if let delta = json["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        return nil
    }
}
