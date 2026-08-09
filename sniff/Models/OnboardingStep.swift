import Foundation


/// A step in the first-run setup flow, in presentation order.
///
/// The flow covers everything Sniff needs before it can answer anything: system permissions, an
/// on-device speech model, and an AI provider credential. Leaving the last one out is what used to
/// let a user finish setup and have their very first question fail with "check your API key".
enum OnboardingStep: Int, CaseIterable, Identifiable {
  case welcome
  case permissions
  case speech
  case ai
  case ready

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .welcome: return "Welcome to Sniff"
    case .permissions: return "Allow access"
    case .speech: return "Choose a transcription model"
    case .ai: return "Connect an AI provider"
    case .ready: return "You're all set"
    }
  }

  var subtitle: String {
    switch self {
    case .welcome:
      return "Sniff listens to your calls and answers on-screen. Setup takes about a minute."
    case .permissions:
      return "Sniff needs these to capture your screen, system audio, and microphone."
    case .speech:
      return "Transcription runs on your Mac. Pick an engine, then download a model."
    case .ai:
      return "Answers come from the provider you choose here. Your key stays in the macOS Keychain."
    case .ready:
      return "Press ⌘⇧W to start a session. These are the shortcuts you'll use most."
    }
  }

  var next: OnboardingStep? {
    OnboardingStep(rawValue: rawValue + 1)
  }

  var previous: OnboardingStep? {
    OnboardingStep(rawValue: rawValue - 1)
  }

  /// Whether this step's requirement is already met. Welcome and ready ask nothing of the user, so
  /// they're always satisfied — they gate nothing, they just bookend the flow.
  func isSatisfied(by readiness: OnboardingReadiness) -> Bool {
    switch self {
    case .welcome, .ready:
      return true
    case .permissions:
      return readiness.permissionsGranted
    case .speech:
      return readiness.speechModelInstalled
    case .ai:
      return readiness.llmCredentialReady
    }
  }

  /// The step the flow opens on. A fresh install starts at the welcome screen; anyone who has
  /// already configured part of Sniff is dropped straight into what's still missing rather than
  /// being walked back through an intro they've seen.
  static func initial(for readiness: OnboardingReadiness) -> OnboardingStep {
    readiness.isUntouched ? .welcome : firstIncomplete(for: readiness)
  }

  static func firstIncomplete(for readiness: OnboardingReadiness) -> OnboardingStep {
    allCases.first { !$0.isSatisfied(by: readiness) } ?? .ready
  }
}

/// Snapshot of what the user has configured, used to decide where the flow opens and which
/// "Continue" buttons are live.
struct OnboardingReadiness: Equatable {
  var permissionsGranted: Bool
  var speechModelInstalled: Bool
  var llmCredentialReady: Bool

  var isComplete: Bool {
    permissionsGranted && speechModelInstalled && llmCredentialReady
  }

  var isUntouched: Bool {
    !permissionsGranted && !speechModelInstalled && !llmCredentialReady
  }
}
