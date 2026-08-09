import SwiftUI


/// Content of the onboarding speech-model step: pick an engine and download a model. Title and
/// navigation come from `OnboardingContainerView`; this view is only the form.
struct TranscriptionModelOnboardingView: View {
  @ObservedObject var coordinator: AppCoordinator
  // See `SpeechModelListView`: the manager must be observed directly for the engine footer and the
  // rows to update the moment a download lands.
  @ObservedObject var downloads: ModelDownloadManager

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    self.downloads = coordinator.modelDownloads
  }

  var body: some View {
    Form {
      Section {
        Picker("Engine", selection: $coordinator.selectedSpeechEngine) {
          ForEach(SpeechEngine.allCases) { engine in
            Text(engine.displayName).tag(engine)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      } footer: {
        Text(coordinator.selectedSpeechEngine == .whisper
          ? "WhisperKit transcribes in short bursts after each pause."
          : "Parakeet (FluidAudio) streams text as you speak, with built-in end-of-utterance detection.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Section {
        SpeechModelListView(coordinator: coordinator, engine: coordinator.selectedSpeechEngine)
      } footer: {
        Text("Downloaded once and cached for future launches. Downloads keep running if you switch engines or close this window.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .onAppear {
      downloads.refreshInstalled()
    }
  }
}
