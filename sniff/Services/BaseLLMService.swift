//
//  BaseLLMService.swift
//  sniff
//

import Foundation

class BaseLLMService: LLMService {
    let apiKey: String
    let baseURL: String

    init(apiKey: String, baseURL: String) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    // MARK: - Abstract methods to override

    func buildTextRequestBody(userMessage: String, systemPrompt: String, options: LLMRequestOptions) -> [String: Any] {
        fatalError("Subclass must override")
    }

    func buildImageRequestBody(userMessage: String, systemPrompt: String, imageData: Data, options: LLMRequestOptions) -> [String: Any] {
        fatalError("Subclass must override")
    }
    
    func configureRequest(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    
    func buildURL() -> URL? {
        URL(string: baseURL)
    }
    
    func parseStreamLine(_ line: String) -> String? {
        fatalError("Subclass must override")
    }
    
    func isStreamDone(_ delta: String) -> Bool {
        delta == "[DONE]"
    }
    
    // MARK: - Shared implementation
    
    func streamAnswer(
        userMessage: String,
        systemPrompt: String,
        options: LLMRequestOptions,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let requestBody = buildTextRequestBody(userMessage: userMessage, systemPrompt: systemPrompt, options: options)
        return try await performStreamRequest(body: requestBody, onChunk: onChunk)
    }

    func streamAnswerWithImage(
        userMessage: String,
        systemPrompt: String,
        imageData: Data,
        options: LLMRequestOptions,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let requestBody = buildImageRequestBody(userMessage: userMessage, systemPrompt: systemPrompt, imageData: imageData, options: options)
        return try await performStreamRequest(body: requestBody, onChunk: onChunk)
    }
    
    private func performStreamRequest(
        body: [String: Any],
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        guard let url = buildURL() else {
            throw LLMError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        configureRequest(&request)
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            throw LLMError.serializationFailed
        }
        request.httpBody = httpBody
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            try await LLMStreamHelpers.throwForFailedHTTPResponse(bytes: bytes, statusCode: httpResponse.statusCode)
        }

        var collected = ""
        for try await line in bytes.lines {
            guard let delta = parseStreamLine(line) else { continue }
            if isStreamDone(delta) { break }
            if !delta.isEmpty {
                collected += delta
                onChunk(delta)
            }
        }
        return collected
    }
    
    // MARK: - Shared parsing helpers
    
    static func parseOpenAIFormat(_ line: String) -> String? {
        guard let payload = LLMStreamHelpers.sseDataPayload(from: line) else { return nil }
        if payload == "[DONE]" { return "[DONE]" }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first else { return nil }

        if let delta = firstChoice["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return content
        }
        if let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        return nil
    }
}
