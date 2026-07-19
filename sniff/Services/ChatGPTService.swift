//
//  ChatGPTService.swift
//  sniff
//

import Foundation

final class ChatGPTService: LLMService {
  private let model: String
  private let authManager: ChatGPTAuthManager
  // ChatGPT subscription (Codex) backend. Uses the Responses API shape, not
  // chat/completions. Must be paired with the Codex OAuth access token.
  private static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

  init(model: String, authManager: ChatGPTAuthManager) {
    self.model = model
    self.authManager = authManager
  }

  func streamAnswer(
    userMessage: String,
    systemPrompt: String,
    options: LLMRequestOptions,
    onChunk: @escaping (String) -> Void
  ) async throws -> String {
    let content: [[String: Any]] = [
      ["type": "input_text", "text": userMessage]
    ]
    let body = Self.buildResponsesBody(model: model, instructions: systemPrompt, content: content)
    return try await performResponsesRequest(body: body, onChunk: onChunk)
  }

  func streamAnswerWithImage(
    userMessage: String,
    systemPrompt: String,
    imageData: Data,
    options: LLMRequestOptions,
    onChunk: @escaping (String) -> Void
  ) async throws -> String {
    let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
    let content: [[String: Any]] = [
      ["type": "input_text", "text": userMessage],
      ["type": "input_image", "image_url": dataURL]
    ]
    let body = Self.buildResponsesBody(model: model, instructions: systemPrompt, content: content)
    return try await performResponsesRequest(body: body, onChunk: onChunk)
  }

  private func performResponsesRequest(body: [String: Any], onChunk: @escaping (String) -> Void) async throws -> String {
    let auth = try await authManager.validAuth()
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(ChatGPTAuthManager.originator, forHTTPHeaderField: "originator")
    request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
    if let accountId = auth.accountId, !accountId.isEmpty {
      request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
    }
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
      guard let delta = Self.parseResponsesSSELine(line) else { continue }
      if delta == "__DONE__" { break }
      if !delta.isEmpty {
        collected += delta
        onChunk(delta)
      }
    }
    return collected
  }

  private static func buildResponsesBody(model: String, instructions: String, content: [[String: Any]]) -> [String: Any] {
    [
      "model": model,
      "instructions": instructions,
      "input": [
        ["type": "message", "role": "user", "content": content]
      ],
      "stream": true,
      "store": false
    ]
  }

  private static func parseResponsesSSELine(_ line: String) -> String? {
    guard let payload = LLMStreamHelpers.sseDataPayload(from: line) else { return nil }
    if payload == "[DONE]" { return "__DONE__" }
    guard let data = payload.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let json = obj as? [String: Any] else { return nil }

    if let type = json["type"] as? String {
      if type.contains("output_text.delta") {
        // Responses API delivers the delta as a plain string.
        if let text = json["delta"] as? String { return text }
        if let delta = json["delta"] as? [String: Any], let text = delta["text"] as? String {
          return text
        }
        if let text = json["text"] as? String { return text }
      }
      if type.contains("response.completed") || type.contains("response.failed") || type == "done" {
        return "__DONE__"
      }
    }
    // Fallbacks for chat/completions-style frames, if the backend ever returns them.
    if let delta = json["delta"] as? String { return delta }
    if let choices = json["choices"] as? [[String: Any]], let first = choices.first,
       let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
      return content
    }
    return nil
  }
}
