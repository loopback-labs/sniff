//
//  LLMStreamHelpers.swift
//  sniff
//

import Foundation

enum LLMStreamHelpers {
  static func sseDataPayload(from line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("data:") else { return nil }
    return String(trimmed.dropFirst(5))
      .trimmingCharacters(in: .whitespaces)
  }

  static func throwForFailedHTTPResponse(
    bytes: URLSession.AsyncBytes,
    statusCode: Int
  ) async throws -> Never {
    var errorBody = ""
    for try await line in bytes.lines {
      errorBody += line
    }
    if let data = errorBody.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let err = json["error"] as? [String: Any],
       let message = err["message"] as? String {
      throw LLMError.apiError(message)
    }
    throw LLMError.httpError(statusCode)
  }
}
