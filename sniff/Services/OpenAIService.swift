import Foundation


class OpenAIService: BaseLLMService {
    private let model: LLMModelOption
    private let thinkingLevel: ThinkingLevel

    init(apiKey: String, model: LLMModelOption, thinkingLevel: ThinkingLevel) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        super.init(apiKey: apiKey, baseURL: "https://api.openai.com/v1/chat/completions")
    }

    override func configureRequest(_ request: inout URLRequest) {
        super.configureRequest(&request)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    override func buildTextRequestBody(userMessage: String, systemPrompt: String, options: LLMRequestOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "stream": true
        ]
        applyModelParameters(to: &body, options: options)
        return body
    }

    override func buildImageRequestBody(userMessage: String, systemPrompt: String, imageData: Data, options: LLMRequestOptions) -> [String: Any] {
        let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
        var body: [String: Any] = [
            "model": model.id,
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
            "stream": true
        ]
        applyModelParameters(to: &body, options: options)
        return body
    }

    /// Reasoning models take `max_completion_tokens` — `max_tokens` is deprecated and rejected.
    private func applyModelParameters(to body: inout [String: Any], options: LLMRequestOptions) {
        body["max_completion_tokens"] = options.maxTokens
        if model.supportsThinkingLevel {
            body["reasoning_effort"] = thinkingLevel.effortValue
        }
    }

    override func parseStreamLine(_ line: String) -> String? {
        Self.parseOpenAIFormat(line)
    }
}
