//
//  OpenAIService.swift
//  sniff
//

import Foundation

class OpenAIService: BaseLLMService {
    private let model: String

    init(apiKey: String, model: String) {
        self.model = model
        super.init(apiKey: apiKey, baseURL: "https://api.openai.com/v1/chat/completions")
    }

    override func configureRequest(_ request: inout URLRequest) {
        super.configureRequest(&request)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    override func buildTextRequestBody(userMessage: String, systemPrompt: String, options: LLMRequestOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": options.maxTokens,
            "stream": true
        ]
        if let temperature = options.temperature {
            body["temperature"] = temperature
        }
        return body
    }

    override func buildImageRequestBody(userMessage: String, systemPrompt: String, imageData: Data, options: LLMRequestOptions) -> [String: Any] {
        let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userMessage],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]
                ]
            ],
            "max_tokens": options.maxTokens,
            "stream": true
        ]
        if let temperature = options.temperature {
            body["temperature"] = temperature
        }
        return body
    }

    override func parseStreamLine(_ line: String) -> String? {
        Self.parseOpenAIFormat(line)
    }
}
