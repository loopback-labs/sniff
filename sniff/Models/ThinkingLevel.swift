import Foundation


/// How long the model reasons before answering. Kept to the three levels every provider accepts so
/// switching provider or model never silently clamps the user's choice.
enum ThinkingLevel: String, CaseIterable, Identifiable {
  case low
  case medium
  case high

  static let `default` = ThinkingLevel.high

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .low: return "Low"
    case .medium: return "Medium"
    case .high: return "High"
    }
  }

  /// Anthropic `output_config.effort`, OpenAI `reasoning_effort`, and the ChatGPT Responses
  /// `reasoning.effort` all take the same lowercase scale.
  var effortValue: String { rawValue }

  var geminiThinkingLevel: String { rawValue.uppercased() }

  static func load(for provider: LLMProvider) -> ThinkingLevel {
    let saved = UserDefaults.standard.string(forKey: UserDefaultsKeys.thinkingLevel(for: provider))
    return saved.flatMap(ThinkingLevel.init(rawValue:)) ?? .default
  }

  static func save(_ level: ThinkingLevel, for provider: LLMProvider) {
    UserDefaults.standard.set(level.rawValue, forKey: UserDefaultsKeys.thinkingLevel(for: provider))
  }
}
