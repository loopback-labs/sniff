//
//  ClaudeService.swift
//  sniff
//

import Foundation

class ClaudeService: BaseLLMService {
    init(apiKey: String) {
        super.init(apiKey: apiKey, baseURL: "https://api.anthropic.com/v1/messages")
    }

    override func configureRequest(_ request: inout URLRequest) {
        super.configureRequest(&request)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    override func buildTextRequestBody(question: String, systemPrompt: String) -> [String: Any] {
        [
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [["role": "user", "content": question]],
            "stream": true
        ]
    }

    override func buildImageRequestBody(prompt: String, imageData: Data) -> [String: Any] {
        [
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
                                "data": imageData.base64EncodedString()
                            ]
                        ],
                        ["type": "text", "text": prompt]
                    ]
                ]
            ],
            "stream": true
        ]
    }

    override func parseStreamLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
        
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String else { return nil }
        return text
    }

    override func isStreamDone(_ delta: String) -> Bool {
        false // Claude doesn't use [DONE]
    }
}
