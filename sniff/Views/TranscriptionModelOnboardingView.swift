//
//  TranscriptionModelOnboardingView.swift
//  sniff
//

import SwiftUI

/// Second onboarding step, shown once permissions are granted: pick a speech engine and download
/// its on-device model before Sniff can transcribe anything.
struct TranscriptionModelOnboardingView: View {
  @ObservedObject var coordinator: AppCoordinator
  // See `SpeechModelListView`: the manager must be observed directly for "Finish" to enable the
  // moment a download lands.
  @ObservedObject var downloads: ModelDownloadManager
  var onFinish: () -> Void

  init(coordinator: AppCoordinator, onFinish: @escaping () -> Void) {
    self.coordinator = coordinator
    self.downloads = coordinator.modelDownloads
    self.onFinish = onFinish
  }

  private var selectedModel: SpeechModel {
    switch coordinator.selectedSpeechEngine {
    case .whisper: return .whisper(coordinator.selectedWhisperModelID)
    case .parakeet: return .parakeet(coordinator.selectedParakeetModelChoice)
    }
  }

  private var canFinish: Bool {
    downloads.isInstalled(selectedModel)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Choose a transcription model")
          .font(.title2.weight(.semibold))

        Text("Sniff transcribes your microphone and system audio on-device. Pick an engine, then download a model to get started.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(20)

      Form {
        Section {
          Picker("Engine", selection: $coordinator.selectedSpeechEngine) {
            ForEach(SpeechEngine.allCases) { engine in
              Text(engine.displayName).tag(engine)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }

        Section {
          SpeechModelListView(coordinator: coordinator, engine: coordinator.selectedSpeechEngine)
        } footer: {
          Text("Downloaded once and cached for future launches. The download continues if you switch engines.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .formStyle(.grouped)
      .frame(height: 430)

      HStack {
        Spacer()
        Button("Finish") {
          onFinish()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canFinish)
      }
      .padding(20)
    }
    .frame(width: 480)
    .onAppear {
      downloads.refreshInstalled()
    }
  }
}
