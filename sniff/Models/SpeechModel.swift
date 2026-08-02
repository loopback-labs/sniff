//
//  SpeechModel.swift
//  sniff
//

import Foundation

/// One downloadable on-device speech model, across both engines.
///
/// Gives Settings, onboarding, and `ModelDownloadManager` a single identity to key download
/// state and copy off of, so a Whisper row and a Parakeet row are the same thing to the UI.
enum SpeechModel: Hashable, Identifiable {
  case whisper(String)
  case parakeet(ParakeetModelChoice)

  var id: String {
    switch self {
    case .whisper(let name): return "whisper.\(name)"
    case .parakeet(let choice): return "parakeet.\(choice.rawValue)"
    }
  }

  var engine: SpeechEngine {
    switch self {
    case .whisper: return .whisper
    case .parakeet: return .parakeet
    }
  }

  static func all(for engine: SpeechEngine) -> [SpeechModel] {
    switch engine {
    case .whisper:
      return LocalWhisperService.availableModelNames.map(SpeechModel.whisper)
    case .parakeet:
      return ParakeetModelChoice.allCases.map(SpeechModel.parakeet)
    }
  }

  var displayName: String {
    switch self {
    case .whisper(let name):
      switch name {
      case "tiny": return "Tiny"
      case "small": return "Small"
      case "medium": return "Medium"
      case "large-v3": return "Large v3"
      default: return name.capitalized
      }
    case .parakeet(let choice):
      return choice.displayName
    }
  }

  /// One-line speed/accuracy guidance so a model row isn't just a bare identifier.
  var detail: String {
    switch self {
    case .whisper(let name):
      switch name {
      case "tiny": return "Fastest, least accurate. Fine for trying things out."
      case "small": return "Balanced speed and accuracy."
      case "medium": return "More accurate, noticeably slower to transcribe."
      case "large-v3": return "Most accurate. Best on Apple silicon with headroom."
      default: return "On-device Whisper model."
      }
    case .parakeet(let choice):
      switch choice {
      case .eou160ms: return "Lowest latency — text appears fastest, slightly less accurate."
      case .eou320ms: return "Balanced latency and accuracy."
      case .eou1280ms: return "Most accurate. Waits longer before finalising each utterance."
      }
    }
  }

  var isRecommended: Bool {
    switch self {
    case .whisper(let name): return name == LocalWhisperService.defaultModelID()
    case .parakeet(let choice): return choice == .eou320ms
    }
  }

  /// Approximate on-disk size shown before download. `nil` when the engine doesn't publish one
  /// ahead of time — the row then falls back to live file counts during the download itself.
  var estimatedSizeBytes: Int64? {
    switch self {
    case .whisper(let name):
      return LocalWhisperService.estimatedModelSizes[LocalWhisperService.normalizedModelID(from: name)]
    case .parakeet:
      return nil
    }
  }
}
