import Foundation


class GeminiService: BaseLLMService {
    private let model: LLMModelOption
    private let thinkingLevel: ThinkingLevel

    init(apiKey: String, model: LLMModelOption, thinkingLevel: ThinkingLevel) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        let url =
          "https://generativelanguage.googleapis.com/v1beta/models/\(model.id):streamGenerateContent"
        super.init(apiKey: apiKey, baseURL: url)
    }

    override func buildURL() -> URL? {
        URL(string: "\(baseURL)?key=\(apiKey)&alt=sse")
    }

    override func buildTextRequestBody(userMessage: String, systemPrompt: String, options: LLMRequestOptions) -> [String: Any] {
        [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": userMessage]]]],
            "generationConfig": generationConfig(for: options)
        ]
    }

    override func buildImageRequestBody(userMessage: String, systemPrompt: String, imageData: Data, options: LLMRequestOptions) -> [String: Any] {
        [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["inline_data": ["mime_type": "image/jpeg", "data": imageData.base64EncodedString()]],
                        ["text": userMessage]
                    ]
                ]
            ],
            "generationConfig": generationConfig(for: options)
        ]
    }

    private func generationConfig(for options: LLMRequestOptions) -> [String: Any] {
        var config: [String: Any] = ["maxOutputTokens": options.maxTokens]
        if model.supportsThinkingLevel {
            config["thinkingConfig"] = ["thinkingLevel": thinkingLevel.geminiThinkingLevel]
        }
        return config
    }

    override func parseStreamLine(_ line: String) -> String? {
        guard let payload = LLMStreamHelpers.sseDataPayload(from: line), !payload.isEmpty else { return nil }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }

        // Thought parts also carry `text`, so skip them rather than taking parts[0] blindly.
        let answerPart = parts.first { ($0["thought"] as? Bool) != true }
        return answerPart?["text"] as? String
    }

    override func isStreamDone(_ delta: String) -> Bool {
        false // Gemini doesn't use [DONE]
    }
}
