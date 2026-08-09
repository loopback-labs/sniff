import SwiftUI


/// The first-run setup flow: welcome → permissions → speech model → AI provider → ready.
///
/// The step is explicit state rather than derived from `AppPermissions.allGranted`, so the flow can
/// cover the AI credential (which the old two-screen version skipped entirely, leaving a new user's
/// first question to fail) and so a user can step back to review what they set.
struct OnboardingContainerView: View {
  @ObservedObject var coordinator: AppCoordinator
  // Observed directly, not through `coordinator.modelDownloads`: the manager is a plain `let` on
  // the coordinator, so its `@Published` changes don't republish the coordinator and "Continue"
  // would never light up when a download lands.
  @ObservedObject var downloads: ModelDownloadManager
  var onFinish: () -> Void

  @State private var step: OnboardingStep

  init(coordinator: AppCoordinator, onFinish: @escaping () -> Void) {
    self.coordinator = coordinator
    self.downloads = coordinator.modelDownloads
    self.onFinish = onFinish
    _step = State(initialValue: OnboardingStep.initial(for: coordinator.onboardingReadiness()))
  }

  private var readiness: OnboardingReadiness {
    OnboardingReadiness(
      permissionsGranted: coordinator.appPermissions.allGranted,
      speechModelInstalled: downloads.isInstalled(coordinator.selectedSpeechModel),
      llmCredentialReady: coordinator.hasLLMCredential
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

      Divider()

      footer
    }
    .frame(width: 520, height: 640)
    .onAppear { downloads.refreshInstalled() }
    .onChange(of: coordinator.appPermissions.allGranted) { _, granted in
      // Granting from System Settings should move the flow along on its own — that round trip is
      // the one moment the user isn't looking at this window.
      if granted, step == .permissions {
        advance()
      }
    }
  }

  // MARK: - Chrome

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(step.title)
        .font(.title2.weight(.semibold))

      Text(step.subtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case .welcome:
      WelcomeStepView()
    case .permissions:
      PermissionOnboardingView(permissions: coordinator.appPermissions)
    case .speech:
      TranscriptionModelOnboardingView(coordinator: coordinator)
    case .ai:
      Form {
        LLMSetupSections(coordinator: coordinator)
      }
      .formStyle(.grouped)
    case .ready:
      ReadyStepView()
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      stepIndicator

      Spacer()

      if let previous = step.previous {
        Button("Back") { step = previous }
      }

      // The AI step is the one requirement Sniff can run without: transcripts and the overlay still
      // work with no provider connected, so skipping is offered rather than the user being trapped.
      if step == .ai, !readiness.llmCredentialReady {
        Button("Skip for now") { advance() }
      }

      Button(primaryTitle) { primaryAction() }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!step.isSatisfied(by: readiness))
    }
    .padding(20)
  }

  private var stepIndicator: some View {
    HStack(spacing: 6) {
      ForEach(OnboardingStep.allCases) { candidate in
        Capsule()
          .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.3))
          .frame(width: candidate == step ? 18 : 6, height: 6)
      }
    }
    .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
  }

  private var primaryTitle: String {
    switch step {
    case .welcome: return "Get Started"
    case .ready: return "Done"
    default: return "Continue"
    }
  }

  private func primaryAction() {
    if step == .ready {
      coordinator.completeOnboarding()
      onFinish()
    } else {
      advance()
    }
  }

  private func advance() {
    guard let next = step.next else { return }
    withAnimation(.easeInOut(duration: 0.15)) {
      step = next
    }
  }
}

// MARK: - Welcome

private struct WelcomeStepView: View {
  private struct Highlight: Identifiable {
    let icon: String
    let title: String
    let detail: String
    var id: String { title }
  }

  private let highlights: [Highlight] = [
    Highlight(
      icon: "waveform",
      title: "Hears both sides of the call",
      detail: "Your microphone and the system audio are transcribed on your Mac — nothing is sent anywhere to do it."
    ),
    Highlight(
      icon: "sparkles",
      title: "Answers on a hotkey",
      detail: "Ask about what's on screen, the last question you heard, or anything you type."
    ),
    Highlight(
      icon: "macwindow",
      title: "Streams into overlay windows",
      detail: "Answers and the live transcript sit above your call, and can be kept out of screen shares."
    ),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(highlights) { highlight in
        HStack(alignment: .top, spacing: 14) {
          Image(systemName: highlight.icon)
            .font(.title3)
            .foregroundStyle(Color.accentColor)
            .frame(width: 28)

          VStack(alignment: .leading, spacing: 3) {
            Text(highlight.title)
              .font(.headline)
            Text(highlight.detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      Spacer(minLength: 0)

      Text("Next: three permissions, a transcription model download, and your AI provider.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 20)
  }
}

// MARK: - Ready

private struct ReadyStepView: View {
  var body: some View {
    Form {
      ForEach(AppShortcut.all) { group in
        Section(group.name) {
          ForEach(group.shortcuts) { shortcut in
            LabeledContent {
              Text(shortcut.keys)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            } label: {
              Text(shortcut.title)
            }
          }
        }
      }

      Section {
        Text("Everything here is in Settings too — open it from the menu bar icon to change models, shortcuts reference, and privacy options.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
  }
}
