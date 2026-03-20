//
//  ChatGPTAuthManager.swift
//  sniff
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class ChatGPTAuthManager: ObservableObject {
  @Published private(set) var isSignedIn: Bool = false
  @Published private(set) var accountHint: String?

  private static let authURL = "https://auth.openai.com/oauth/authorize"
  private static let tokenURL = "https://auth.openai.com/oauth/token"
  private static let callbackPath = "/auth/callback"
  private static let defaultPort: UInt16 = 1455

  private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

  private let tokenFileURL: URL

  struct StoredSession: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var accountId: String?
  }

  init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let dir = support.appendingPathComponent("sniff", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tokenFileURL = dir.appendingPathComponent("chatgpt-auth.json")
    loadFromDisk()
  }

  func signOut() {
    try? FileManager.default.removeItem(at: tokenFileURL)
    isSignedIn = false
    accountHint = nil
  }

  func validAccessToken() async throws -> String {
    guard var session = readSession() else {
      throw ChatGPTAuthError.notSignedIn
    }
    if let exp = session.expiresAt, exp > Date().addingTimeInterval(120) {
      return session.accessToken
    }
    guard let refresh = session.refreshToken, !refresh.isEmpty else {
      throw ChatGPTAuthError.notSignedIn
    }
    session = try await refreshTokens(refreshToken: refresh)
    try saveSession(session)
    isSignedIn = true
    accountHint = session.accountId
    return session.accessToken
  }

  func signInWithBrowser() async throws {
    let clientId = Self.clientID

    let verifier = Self.makeCodeVerifier()
    let challenge = Self.codeChallengeS256(verifier: verifier)
    let state = Self.randomURLSafeString(byteCount: 32)

    let port = Self.defaultPort
    let redirectURI = "http://127.0.0.1:\(port)\(Self.callbackPath)"

    let server = try OAuthLoopbackServer(port: port, path: Self.callbackPath)

    var components = URLComponents(string: Self.authURL)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "scope", value: "openid offline_access"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "originator", value: "opencode")
    ]
    guard let url = components.url else {
      throw ChatGPTAuthError.invalidAuthURL
    }

    let queryString: String
    do {
      queryString = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
        server.start { result in
          switch result {
          case .success(let q): cont.resume(returning: q)
          case .failure(let e): cont.resume(throwing: e)
          }
        }
        NSWorkspace.shared.open(url)
      }
    } catch {
      server.cancel()
      throw error
    }
    server.cancel()

    guard let parsed = Self.parseCallbackQuery(queryString) else {
      throw ChatGPTAuthError.callbackParseFailed
    }
    if let err = parsed.error {
      throw ChatGPTAuthError.oauthError(err, parsed.errorDescription)
    }
    guard let code = parsed.code, let returnedState = parsed.state else {
      throw ChatGPTAuthError.missingAuthorizationCode
    }
    guard returnedState == state else {
      throw ChatGPTAuthError.stateMismatch
    }

    let session = try await exchangeCodeForTokens(
      code: code,
      redirectURI: redirectURI,
      codeVerifier: verifier,
      clientId: clientId
    )
    try saveSession(session)
    isSignedIn = true
    accountHint = session.accountId
  }

  private func loadFromDisk() {
    if let s = readSession() {
      isSignedIn = true
      accountHint = s.accountId
    }
  }

  private func readSession() -> StoredSession? {
    guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
    return try? JSONDecoder().decode(StoredSession.self, from: data)
  }

  private func saveSession(_ session: StoredSession) throws {
    let data = try JSONEncoder().encode(session)
    try data.write(to: tokenFileURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
  }

  private func exchangeCodeForTokens(
    code: String,
    redirectURI: String,
    codeVerifier: String,
    clientId: String
  ) async throws -> StoredSession {
    var request = URLRequest(url: URL(string: Self.tokenURL)!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let body = [
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirectURI,
      "client_id": clientId,
      "code_verifier": codeVerifier
    ]
    request.httpBody = Self.formURLEncoded(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ChatGPTAuthError.tokenExchangeFailed("Invalid response")
    }
    guard (200...299).contains(http.statusCode) else {
      let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
      throw ChatGPTAuthError.tokenExchangeFailed(msg)
    }
    return try Self.decodeTokenResponse(data)
  }

  private func refreshTokens(refreshToken: String) async throws -> StoredSession {
    let clientId = Self.clientID
    var request = URLRequest(url: URL(string: Self.tokenURL)!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body = [
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": clientId
    ]
    request.httpBody = Self.formURLEncoded(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let msg = String(data: data, encoding: .utf8) ?? "refresh failed"
      throw ChatGPTAuthError.tokenExchangeFailed(msg)
    }
    return try Self.decodeTokenResponse(data, previousRefresh: refreshToken)
  }

  private static func decodeTokenResponse(_ data: Data, previousRefresh: String? = nil) throws -> StoredSession {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ChatGPTAuthError.tokenExchangeFailed("Invalid JSON")
    }
    guard let access = json["access_token"] as? String else {
      throw ChatGPTAuthError.tokenExchangeFailed("Missing access_token")
    }
    let refresh = (json["refresh_token"] as? String) ?? previousRefresh
    var expiresAt: Date?
    if let exp = json["expires_in"] as? Int {
      expiresAt = Date().addingTimeInterval(TimeInterval(exp))
    } else if let exp = json["expires_in"] as? Double {
      expiresAt = Date().addingTimeInterval(exp)
    }
    let accountFromJWT = Self.chatgptAccountIdFromAccessTokenJWT(access)
    let accountFromBody = json["sub"] as? String ?? json["account_id"] as? String
    let accountId = accountFromJWT ?? accountFromBody
    return StoredSession(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, accountId: accountId)
  }

  private static func chatgptAccountIdFromAccessTokenJWT(_ accessToken: String) -> String? {
    let parts = accessToken.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    let payload = String(parts[1])
    guard let data = base64URLDecode(payload) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let id = obj["chatgpt_account_id"] as? String, !id.isEmpty { return id }
    if let auth = obj["https://api.openai.com/auth"] as? [String: Any],
       let id = auth["chatgpt_account_id"] as? String, !id.isEmpty {
      return id
    }
    if let orgs = obj["organizations"] as? [[String: Any]],
       let first = orgs.first,
       let id = first["id"] as? String, !id.isEmpty {
      return id
    }
    return nil
  }

  private static func base64URLDecode(_ string: String) -> Data? {
    var s = string
    let remainder = s.count % 4
    if remainder > 0 {
      s += String(repeating: "=", count: 4 - remainder)
    }
    s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: s)
  }

  private static func makeCodeVerifier() -> String {
    randomURLSafeString(byteCount: 32)
  }

  private static func codeChallengeS256(verifier: String) -> String {
    let hash = SHA256.hash(data: Data(verifier.utf8))
    return Data(hash).base64URLEncodedString()
  }

  private static func randomURLSafeString(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    guard status == errSecSuccess else {
      return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
    return Data(bytes).base64URLEncodedString()
  }

  private static func formURLEncoded(_ pairs: [String: String]) -> Data {
    let s = pairs
      .map { key, val in
        "\(key.urlFormEncoded())=\(val.urlFormEncoded())"
      }
      .joined(separator: "&")
    return Data(s.utf8)
  }

  private static func parseCallbackQuery(_ query: String) -> (code: String?, state: String?, error: String?, errorDescription: String?)? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var dict: [String: String] = [:]
    for pair in trimmed.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
      if kv.count == 2 {
        dict[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
      } else if kv.count == 1 {
        dict[kv[0]] = ""
      }
    }
    return (
      dict["code"],
      dict["state"],
      dict["error"],
      dict["error_description"]
    )
  }
}

// MARK: - Loopback server

private final class OAuthLoopbackServer {
  private let listener: NWListener
  private let path: String
  private var onComplete: ((Result<String, Error>) -> Void)?
  private let queue = DispatchQueue(label: "com.loopbacklabs.sniff.oauth")

  init(port: UInt16, path: String) throws {
    self.path = path
    guard let p = NWEndpoint.Port(rawValue: port) else {
      throw ChatGPTAuthError.listenerFailed("Invalid port")
    }
    self.listener = try NWListener(using: .tcp, on: p)
  }

  func start(completion: @escaping (Result<String, Error>) -> Void) {
    onComplete = completion
    listener.stateUpdateHandler = { [weak self] state in
      if case .failed(let err) = state {
        self?.finish(.failure(err))
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: queue)
  }

  func cancel() {
    listener.cancel()
    onComplete = nil
  }

  private func finish(_ result: Result<String, Error>) {
    guard let cb = onComplete else { return }
    onComplete = nil
    listener.cancel()
    cb(result)
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection: connection, buffer: Data())
  }

  private func read(connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }
      if let error = error {
        self.finish(.failure(error))
        return
      }
      var buf = buffer
      if let data = data { buf.append(data) }
      if let s = String(data: buf, encoding: .utf8), s.contains("\r\n\r\n") {
        self.parseRequest(buf, connection: connection)
        return
      }
      if isComplete {
        self.parseRequest(buf, connection: connection)
        return
      }
      self.read(connection: connection, buffer: buf)
    }
  }

  private func parseRequest(_ raw: Data, connection: NWConnection) {
    guard let req = String(data: raw, encoding: .utf8) else {
      sendHTML(connection: connection, status: "400 Bad Request", body: "Bad request")
      finish(.failure(ChatGPTAuthError.callbackParseFailed))
      return
    }
    let headerEnd = req.range(of: "\r\n\r\n")
    let head = headerEnd.map { String(req[..<$0.lowerBound]) } ?? req
    let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let first = lines.first else {
      sendHTML(connection: connection, status: "400 Bad Request", body: "Bad request")
      finish(.failure(ChatGPTAuthError.callbackParseFailed))
      return
    }
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else {
      sendHTML(connection: connection, status: "400 Bad Request", body: "Bad request")
      finish(.failure(ChatGPTAuthError.callbackParseFailed))
      return
    }
    let target = String(parts[1])
    guard target.hasPrefix(path) else {
      sendHTML(connection: connection, status: "404 Not Found", body: "Not found")
      connection.cancel()
      return
    }
    let query: String
    if let qRange = target.range(of: "?") {
      query = String(target[qRange.upperBound...])
    } else {
      query = ""
    }
    sendHTML(connection: connection, status: "200 OK", body: "<html><body><p>Sign-in complete. You can return to Sniff.</p></body></html>")
    connection.cancel()
    finish(.success(query))
  }

  private func sendHTML(connection: NWConnection, status: String, body: String) {
    let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    connection.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in })
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    self.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private extension String {
  func urlFormEncoded() -> String {
    addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))) ?? self
  }
}

enum ChatGPTAuthError: LocalizedError {
  case missingClientID
  case invalidAuthURL
  case notSignedIn
  case listenerFailed(String)
  case callbackParseFailed
  case missingAuthorizationCode
  case stateMismatch
  case oauthError(String, String?)
  case tokenExchangeFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingClientID:
      return "ChatGPT client ID is missing from configuration."
    case .invalidAuthURL:
      return "Could not build authorization URL."
    case .notSignedIn:
      return "Not signed in to ChatGPT."
    case .listenerFailed(let s):
      return "Could not start local callback server: \(s). Port may be in use."
    case .callbackParseFailed:
      return "Could not parse OAuth callback."
    case .missingAuthorizationCode:
      return "Authorization code missing from callback."
    case .stateMismatch:
      return "OAuth state mismatch (possible CSRF)."
    case .oauthError(let code, let desc):
      return "OAuth error: \(code)\(desc.map { " — \($0)" } ?? "")"
    case .tokenExchangeFailed(let s):
      return "Token exchange failed: \(s)"
    }
  }
}
