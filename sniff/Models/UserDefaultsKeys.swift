//
//  UserDefaultsKeys.swift
//  sniff
//

import Foundation

enum UserDefaultsKeys {
  static let selectedLLMProvider = "selectedLLMProvider"
  static let selectedSpeechEngine = "selectedSpeechEngine"
  static let selectedParakeetModelChoice = "selectedParakeetModelChoice"
  static let showOverlay = "showOverlay"
  static let selectedAudioInputDeviceUID = "selectedAudioInputDeviceUID"
  static let whisperModelId = "whisperModelId"

  static let llmModelIdPrefix = "llmModelId_"

  static func llmModelId(for provider: LLMProvider) -> String {
    "\(llmModelIdPrefix)\(provider.rawValue)"
  }
}
