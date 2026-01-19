//
//  GeminiService.swift
//  sniff
//

import Foundation

class GeminiService: LLMService {
    private let apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent"
    
    init(apiKey: String) {
        self.apiKey = apiKey
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
            "system_instruction": [
                "parts": [["text": systemPrompt]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": question]]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 1024,
                "temperature": 0.2
            ]
        ]

        guard let url = URL(string: "\(baseURL)?key=\(apiKey)&alt=sse") else {
            throw LLMError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            return nil
        }

        return text
    }
}
