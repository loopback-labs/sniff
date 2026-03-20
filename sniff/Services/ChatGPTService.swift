//
//  ChatGPTService.swift
//  sniff
//

import Foundation

final class ChatGPTService: LLMService {
  private let model: String
  private let authManager: ChatGPTAuthManager
  private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/responses")!

  init(model: String, authManager: ChatGPTAuthManager) {
    self.model = model
    self.authManager = authManager
  }

  func streamAnswer(
    _ question: String,
    screenContext: String?,
    onChunk: @escaping (String) -> Void
  ) async throws -> String {
    var systemPrompt = BaseLLMService.defaultSystemPrompt
    if let context = screenContext, !context.isEmpty {
      systemPrompt += " Here is the current screen context: \(context)"
    }
    let body = Self.buildChatBody(model: model, systemPrompt: systemPrompt, userText: question)
    return try await performWhamRequest(body: body, onChunk: onChunk)
  }

  func streamAnswerWithImage(
    prompt: String,
    imageData: Data,
    onChunk: @escaping (String) -> Void
  ) async throws -> String {
    let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
    let body: [String: Any] = [
      "model": model,
      "stream": true,
      "messages": [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": prompt],
            ["type": "image_url", "image_url": ["url": dataURL]]
          ]
        ]
      ]
    ]
    return try await performWhamRequest(body: body, onChunk: onChunk)
  }

  private func performWhamRequest(body: [String: Any], onChunk: @escaping (String) -> Void) async throws -> String {
    let token = try await authManager.validAccessToken()
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
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
      guard let delta = Self.parseWhamSSELine(line) else { continue }
      if delta == "__DONE__" { break }
      if !delta.isEmpty {
        collected += delta
        onChunk(delta)
      }
    }
    return collected
  }

  private static func buildChatBody(model: String, systemPrompt: String, userText: String) -> [String: Any] {
    [
      "model": model,
      "stream": true,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": userText]
      ]
    ]
  }

  private static func parseWhamSSELine(_ line: String) -> String? {
    guard let payload = LLMStreamHelpers.sseDataPayload(from: line) else { return nil }
    if payload == "[DONE]" { return "__DONE__" }
    guard let data = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let json = obj as? [String: Any] else { return nil }

    if let type = json["type"] as? String {
        if type.contains("output_text.delta") || type.contains("response.output_text.delta") {
          if let delta = json["delta"] as? [String: Any], let text = delta["text"] as? String {
            return text
          }
          if let text = json["text"] as? String { return text }
        }
      if type.contains("completed") || type.contains("done") {
        return "__DONE__"
      }
    }
    if let delta = json["delta"] as? [String: Any], let text = delta["text"] as? String {
      return text
    }
    if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
      if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
        return content
      }
    }
    return nil
  }
}
