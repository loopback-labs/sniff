//
//  OpenAIService.swift
//  sniff
//

import Foundation

class OpenAIService: BaseLLMService {
    init(apiKey: String) {
        super.init(apiKey: apiKey, baseURL: "https://api.openai.com/v1/chat/completions")
    }

    override func configureRequest(_ request: inout URLRequest) {
        super.configureRequest(&request)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    override func buildTextRequestBody(question: String, systemPrompt: String) -> [String: Any] {
        [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": question]
            ],
            "max_tokens": 1024,
            "temperature": 0.2,
            "stream": true
        ]
    }

    override func buildImageRequestBody(prompt: String, imageData: Data) -> [String: Any] {
        let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        return [
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
    }

    override func parseStreamLine(_ line: String) -> String? {
        Self.parseOpenAIFormat(line)
    }
}
