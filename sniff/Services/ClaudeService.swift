import Foundation


class ClaudeService: BaseLLMService {
    private let model: LLMModelOption
    private let thinkingLevel: ThinkingLevel

    init(apiKey: String, model: LLMModelOption, thinkingLevel: ThinkingLevel) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        super.init(apiKey: apiKey, baseURL: "https://api.anthropic.com/v1/messages")
    }

    override func configureRequest(_ request: inout URLRequest) {
        super.configureRequest(&request)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    override func buildTextRequestBody(userMessage: String, systemPrompt: String, options: LLMRequestOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": options.maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
            "stream": true
        ]
        applyThinkingParameters(to: &body)
        return body
    }

    override func buildImageRequestBody(userMessage: String, systemPrompt: String, imageData: Data, options: LLMRequestOptions) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": options.maxTokens,
            "system": systemPrompt,
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
                        ["type": "text", "text": userMessage]
                    ]
                ]
            ],
            "stream": true
        ]
        applyThinkingParameters(to: &body)
        return body
    }

    private func applyThinkingParameters(to body: inout [String: Any]) {
        guard model.supportsThinkingLevel else { return }
        body["thinking"] = ["type": "adaptive"]
        body["output_config"] = ["effort": thinkingLevel.effortValue]
    }

    override func parseStreamLine(_ line: String) -> String? {
        guard let payload = LLMStreamHelpers.sseDataPayload(from: line) else { return nil }

        // Thinking deltas carry `delta.thinking`, so keying off `delta.text` skips them.
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
