//
//  PerplexityService.swift
//  sniff
//

import Foundation

class PerplexityService: BaseLLMService {
    init(apiKey: String) {
        super.init(apiKey: apiKey, baseURL: "https://api.perplexity.ai/chat/completions")
    }

    override func configureRequest(_ request: inout URLRequest) {
        super.configureRequest(&request)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    override func buildTextRequestBody(question: String, systemPrompt: String) -> [String: Any] {
        [
            "model": "sonar",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": question]
            ],
            "max_tokens": 1024,
            "temperature": 0.2,
            "stream": true
        ]
    }

    override func streamAnswerWithImage(
        prompt: String,
        imageData: Data,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: "https://api.perplexity.ai/v1/responses") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "openai/gpt-5-mini",
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": prompt],
                        ["type": "input_image", "image_url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"]
                    ]
                ]
            ]
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMError.serializationFailed
        }
        request.httpBody = httpBody

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let message = err["message"] as? String {
                throw LLMError.apiError(message)
            }
            throw LLMError.httpError(httpResponse.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = json["output_text"] as? String else {
            throw LLMError.invalidResponse
        }
        onChunk(answer)
        return answer
    }

    override func parseStreamLine(_ line: String) -> String? {
        Self.parseOpenAIFormat(line)
    }
}
