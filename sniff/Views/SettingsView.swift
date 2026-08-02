//
//  SettingsView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI
import CoreAudio
import AppKit

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var apiKey: String = ""
    @State private var apiKeyUI = APIKeyUIState()
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var chatGPTAuthUIVersion = 0
    private let keychainService = KeychainService()

    private var audioDeviceService: AudioDeviceService { coordinator.audioDeviceService }

    private func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                aiTab
                    .tabItem { Label("AI", systemImage: "brain") }

                speechTab
                    .tabItem { Label("Speech", systemImage: "waveform") }

                shortcutsTab
                    .tabItem { Label("Shortcuts", systemImage: "command") }

                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
            }

            // Sits outside the TabView so an in-progress model download stays visible no matter
            // which tab is on screen.
            ActiveDownloadsBar(downloads: coordinator.modelDownloads)
        }
        .frame(width: 620, height: 660)
        .onAppear {
            loadAPIKey()
            loadSelectedDevice()
        }
        .alert("Settings", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - AI tab

    private var aiTab: some View {
        Form {
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
        .formStyle(.grouped)
    }

    /// Replaces the old static "screen questions need vision" footer with the actual capability of
    /// the model that's currently selected.
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
        if apiKeyUI.hasStoredKey && !apiKeyUI.isEditing {
            LabeledContent("Key") {
                HStack(spacing: 8) {
                    Text(apiKeyUI.isViewingSecret ? apiKey : "••••••••••••••••")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(apiKeyUI.isViewingSecret ? .primary : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button {
                        toggleViewMode()
                    } label: {
                        Image(systemName: apiKeyUI.isViewingSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(apiKeyUI.isViewingSecret ? "Hide key" : "Reveal key")
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

            HStack {
                Button("Save") { saveAPIKey() }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if apiKeyUI.hasStoredKey {
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
                // The hint is an opaque account ID unless it happens to be an address, so it goes
                // in a tooltip rather than being displayed as a meaningless UUID.
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
                            showAlert(error.localizedDescription)
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Speech tab

    private var speechTab: some View {
        Form {
            Section {
                Picker("Engine", selection: $coordinator.selectedSpeechEngine) {
                    ForEach(SpeechEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Engine")
            } footer: {
                Text(coordinator.selectedSpeechEngine == .whisper
                    ? "WhisperKit transcribes microphone and system audio on-device, in short bursts after each pause."
                    : "Parakeet (FluidAudio) streams text on-device as you speak, with built-in end-of-utterance detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                SpeechModelListView(coordinator: coordinator, engine: coordinator.selectedSpeechEngine)
            } header: {
                Text("\(coordinator.selectedSpeechEngine.displayName) Model")
            } footer: {
                Text("Downloaded once to app storage and reused on every launch. Downloads keep running if you switch tabs or close this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Audio Input") {
                Picker("Microphone", selection: $selectedDeviceID) {
                    Text("System default").tag(AudioDeviceID(0))
                    ForEach(audioDeviceService.inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceID) { _, newValue in
                    setInputDevice(newValue)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcuts tab

    private var shortcutsTab: some View {
        Form {
            ForEach(AppShortcut.all) { group in
                Section(group.name) {
                    ForEach(group.shortcuts) { shortcut in
                        LabeledContent {
                            Text(shortcut.keys)
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortcut.title)
                                Text(shortcut.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - General tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Include overlays in screenshots", isOn: $coordinator.showOverlay)
            } header: {
                Text("Privacy")
            } footer: {
                Text("When off, Sniff's overlays stay invisible in screen shares and captures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permissions") {
                ForEach(AppPermissionKind.allCases) { kind in
                    permissionRow(kind)
                }
            }

            Section("Storage") {
                LabeledContent("Transcripts") {
                    Button("Show in Finder") {
                        revealInFinder(AppCoordinator.transcriptSaveDirectory)
                    }
                }

                DownloadedModelsSizeRow(downloads: coordinator.modelDownloads)
            }
        }
        .formStyle(.grouped)
        .task {
            await coordinator.appPermissions.refreshAccurate()
            coordinator.modelDownloads.refreshInstalled()
        }
    }

    @ViewBuilder
    private func permissionRow(_ kind: AppPermissionKind) -> some View {
        let granted = coordinator.appPermissions.isGranted(kind)

        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Open Settings") {
                    coordinator.appPermissions.openSystemSettings(for: kind)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func revealInFinder(_ url: URL) {
        // Created on demand: the transcripts folder doesn't exist until the first session runs.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - API Key Management

    private func loadAPIKey() {
        guard !coordinator.selectedProvider.usesOAuth else {
            apiKey = ""
            apiKeyUI = APIKeyUIState()
            return
        }
        let stored = keychainService.getAPIKey(for: coordinator.selectedProvider)
        apiKey = stored ?? ""
        let has = stored.map { !$0.isEmpty } ?? false
        apiKeyUI = APIKeyUIState(hasStoredKey: has, isEditing: false, isViewingSecret: false)
    }

    private func enterEditMode() {
        loadAPIKey()
        apiKeyUI.isEditing = true
        apiKeyUI.isViewingSecret = false
        apiKey = ""
    }

    private func cancelEdit() {
        loadAPIKey()
    }

    private func toggleViewMode() {
        if apiKeyUI.isViewingSecret {
            apiKeyUI.isViewingSecret = false
        } else {
            loadAPIKey()
            apiKeyUI.isViewingSecret = true
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showAlert("API key cannot be empty")
            return
        }

        do {
            try keychainService.saveAPIKey(trimmed, for: coordinator.selectedProvider)
            coordinator.updateAPIKey(trimmed, for: coordinator.selectedProvider)
            apiKey = trimmed
            apiKeyUI.hasStoredKey = true
            apiKeyUI.isEditing = false
        } catch {
            showAlert("Failed to save API key: \(error.localizedDescription)")
        }
    }

    private func clearAPIKey() {
        guard !coordinator.selectedProvider.usesOAuth else { return }
        do {
            try keychainService.deleteAPIKey(for: coordinator.selectedProvider)
            apiKey = ""
            apiKeyUI = APIKeyUIState()
            coordinator.rebuildLLMService()
        } catch {
            showAlert("Failed to clear API key: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio Device Management

    private func loadSelectedDevice() {
        if let savedUID = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedAudioInputDeviceUID),
           let device = audioDeviceService.inputDevices.first(where: { $0.uid == savedUID }) {
            selectedDeviceID = device.id
        } else if let defaultID = audioDeviceService.defaultInputDeviceID {
            selectedDeviceID = defaultID
        }
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) {
        guard deviceID != 0 else { return }
        do {
            try audioDeviceService.setDefaultInputDevice(deviceID)
            if let device = audioDeviceService.inputDevices.first(where: { $0.id == deviceID }) {
                UserDefaults.standard.set(device.uid, forKey: UserDefaultsKeys.selectedAudioInputDeviceUID)
            }
        } catch {
            showAlert(error.localizedDescription)
        }
    }
}

// MARK: - Storage

/// Observes the manager directly so the figure updates when a model is downloaded or removed.
private struct DownloadedModelsSizeRow: View {
    @ObservedObject var downloads: ModelDownloadManager

    var body: some View {
        LabeledContent("Downloaded models") {
            Text(downloads.totalInstalledSizeString() ?? "None")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - State

private struct APIKeyUIState {
    var hasStoredKey = false
    var isEditing = false
    var isViewingSecret = false
}

#Preview("Settings") {
    SettingsView()
        .environmentObject(AppCoordinator())
}
