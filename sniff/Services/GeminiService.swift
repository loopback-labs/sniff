//
//  GeminiService.swift
//  sniff
//

import Foundation

class GeminiService: BaseLLMService {
    init(apiKey: String) {
        super.init(apiKey: apiKey, baseURL: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent")
    }

    override func buildURL() -> URL? {
        URL(string: "\(baseURL)?key=\(apiKey)&alt=sse")
    }

    override func buildTextRequestBody(question: String, systemPrompt: String) -> [String: Any] {
        [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": question]]]],
            "generationConfig": ["maxOutputTokens": 4096, "temperature": 0.2]
        ]
    }

    override func buildImageRequestBody(prompt: String, imageData: Data) -> [String: Any] {
        [
            "system_instruction": ["parts": [["text": Self.defaultSystemPrompt]]],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["inline_data": ["mime_type": "image/jpeg", "data": imageData.base64EncodedString()]],
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": ["maxOutputTokens": 4096, "temperature": 0.2]
        ]
    }

    override func parseStreamLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              !candidates.isEmpty,
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              !parts.isEmpty,
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else { return nil }
        return text
    }

    override func isStreamDone(_ delta: String) -> Bool {
        false // Gemini doesn't use [DONE]
    }
}
