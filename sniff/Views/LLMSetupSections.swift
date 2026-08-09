import SwiftUI


/// Provider, model, and credential rows as `Form` sections. Shared by `SettingsView`'s AI tab and
/// the onboarding AI step — same pattern as `SpeechModelListView`, so connecting a provider during
/// setup and changing it later are the same UI rather than two implementations that drift.
///
/// Host it inside a `Form { }.formStyle(.grouped)`.
struct LLMSetupSections: View {
  @ObservedObject var coordinator: AppCoordinator

  @State private var apiKey: String = ""
  @State private var keyUI = APIKeyUIState()
  @State private var chatGPTAuthUIVersion = 0
  @State private var errorMessage: String?

  private let keychainService = KeychainService()

  var body: some View {
    Group {
      Section("Model") {
        Picker("Provider", selection: $coordinator.selectedProvider) {
          ForEach(LLMProvider.allCases) { provider in
            Text(provider.displayName).tag(provider)
          }
        }
        .onChange(of: coordinator.selectedProvider) { _, _ in
          loadAPIKey()
        }

        Picker("Model", selection: $coordinator.selectedModelId) {
          ForEach(LLMModelCatalog.models(for: coordinator.selectedProvider)) { option in
            Text(option.displayName).tag(option.id)
          }
        }

        visionCapabilityRow
      }

      if coordinator.selectedProvider.usesOAuth {
        Section("ChatGPT Account") {
          chatGPTAuthSection
            .id(chatGPTAuthUIVersion)
        }
      } else {
        Section {
          apiKeySection
        } header: {
          Text("\(coordinator.selectedProvider.displayName) API Key")
        } footer: {
          HStack(spacing: 4) {
            Text("Stored in your macOS Keychain.")
            if let url = coordinator.selectedProvider.apiKeyURL {
              Link("Get a key", destination: url)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .onAppear { loadAPIKey() }
    .alert(
      "AI Provider",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  /// Reports the actual capability of the currently selected model rather than a static
  /// "screen questions need vision" note.
  @ViewBuilder
  private var visionCapabilityRow: some View {
    let supportsVision = LLMModelCatalog.supportsVision(
      provider: coordinator.selectedProvider,
      modelId: coordinator.selectedModelId
    )

    Label {
      Text(supportsVision
        ? "Reads screenshots — screen questions (⌘⇧Q) work."
        : "No image input — screen questions (⌘⇧Q) will fail with this model.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: supportsVision ? "eye" : "eye.slash")
        .foregroundStyle(supportsVision ? Color.green : Color.orange)
    }
  }

  @ViewBuilder
  private var apiKeySection: some View {
    if keyUI.hasStoredKey && !keyUI.isEditing {
      LabeledContent("Key") {
        HStack(spacing: 8) {
          Text(keyUI.isViewingSecret ? apiKey : "••••••••••••••••")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(keyUI.isViewingSecret ? .primary : .secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)

          Button {
            toggleViewMode()
          } label: {
            Image(systemName: keyUI.isViewingSecret ? "eye.slash" : "eye")
          }
          .buttonStyle(.borderless)
          .help(keyUI.isViewingSecret ? "Hide key" : "Reveal key")
        }
      }

      HStack {
        Button("Replace") { enterEditMode() }
        Spacer()
        Button("Remove", role: .destructive) { clearAPIKey() }
      }
    } else {
      SecureField("Paste your API key", text: $apiKey)
        .textFieldStyle(.roundedBorder)
        .onSubmit { saveAPIKey() }

      HStack {
        Button("Save") { saveAPIKey() }
          .buttonStyle(.borderedProminent)
          .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if keyUI.hasStoredKey {
          Button("Cancel") { cancelEdit() }
        }

        Spacer()
      }
    }
  }

  private var chatGPTStatusText: String {
    guard let hint = coordinator.chatGPTAuthManager.accountHint, hint.contains("@") else {
      return "Signed in"
    }
    return hint
  }

  @ViewBuilder
  private var chatGPTAuthSection: some View {
    if coordinator.chatGPTAuthManager.isSignedIn {
      LabeledContent("Status") {
        Label {
          Text(chatGPTStatusText)
        } icon: {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
        // The hint is an opaque account ID unless it happens to be an address, so it goes in a
        // tooltip rather than being displayed as a meaningless UUID.
        .help(coordinator.chatGPTAuthManager.accountHint.map { "Account \($0)" } ?? "")
      }

      HStack {
        Spacer()
        Button("Sign Out", role: .destructive) {
          coordinator.chatGPTAuthManager.signOut()
          coordinator.refreshLLMAfterChatGPTAuth()
          chatGPTAuthUIVersion += 1
        }
      }
    } else {
      Text("Sign in with your ChatGPT account to use it as the provider — no API key needed.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button("Sign In with ChatGPT") {
        Task {
          do {
            try await coordinator.chatGPTAuthManager.signInWithBrowser()
            await MainActor.run {
              coordinator.refreshLLMAfterChatGPTAuth()
              chatGPTAuthUIVersion += 1
            }
          } catch {
            await MainActor.run {
              errorMessage = error.localizedDescription
            }
          }
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }

  // MARK: - API key management

  private func loadAPIKey() {
    guard !coordinator.selectedProvider.usesOAuth else {
      apiKey = ""
      keyUI = APIKeyUIState()
      return
    }
    let stored = keychainService.getAPIKey(for: coordinator.selectedProvider)
    apiKey = stored ?? ""
    let has = stored.map { !$0.isEmpty } ?? false
    keyUI = APIKeyUIState(hasStoredKey: has, isEditing: false, isViewingSecret: false)
  }

  private func enterEditMode() {
    loadAPIKey()
    keyUI.isEditing = true
    keyUI.isViewingSecret = false
    apiKey = ""
  }

  private func cancelEdit() {
    loadAPIKey()
  }

  private func toggleViewMode() {
    if keyUI.isViewingSecret {
      keyUI.isViewingSecret = false
    } else {
      loadAPIKey()
      keyUI.isViewingSecret = true
    }
  }

  private func saveAPIKey() {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      errorMessage = "API key cannot be empty"
      return
    }

    do {
      try keychainService.saveAPIKey(trimmed, for: coordinator.selectedProvider)
      coordinator.updateAPIKey(trimmed, for: coordinator.selectedProvider)
      apiKey = trimmed
      keyUI.hasStoredKey = true
      keyUI.isEditing = false
    } catch {
      errorMessage = "Failed to save API key: \(error.localizedDescription)"
    }
  }

  private func clearAPIKey() {
    guard !coordinator.selectedProvider.usesOAuth else { return }
    do {
      try keychainService.deleteAPIKey(for: coordinator.selectedProvider)
      apiKey = ""
      keyUI = APIKeyUIState()
      coordinator.rebuildLLMService()
    } catch {
      errorMessage = "Failed to clear API key: \(error.localizedDescription)"
    }
  }
}

private struct APIKeyUIState {
  var hasStoredKey = false
  var isEditing = false
  var isViewingSecret = false
}
