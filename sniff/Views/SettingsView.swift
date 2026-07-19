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
    @State private var whisperModelID: String = LocalWhisperService.defaultModelID()
    @State private var downloadedModels: [String] = []
    @State private var downloadingModelName: String?
    @State private var modelSizes: [String: String] = [:]
    @State private var chatGPTAuthUIVersion = 0
    private let keychainService = KeychainService()

    private var audioDeviceService: AudioDeviceService { coordinator.audioDeviceService }

    private func showAlert(_ message: String) {
        alertMessage = message
        showingAlert = true
    }

    var body: some View {
        TabView {
            aiTab
                .tabItem { Label("AI", systemImage: "brain") }

            speechTab
                .tabItem { Label("Speech", systemImage: "waveform") }

            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 620)
        .onAppear {
            loadAPIKey()
            loadSelectedDevice()
            loadWhisperModelSelection()
            listDownloadedModels()
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
            Section {
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
            } footer: {
                Text("Screen questions require a vision-capable model for this provider.")
            }

            if coordinator.selectedProvider.usesOAuth {
                Section("ChatGPT account") {
                    chatGPTAuthSection
                        .id(chatGPTAuthUIVersion)
                }
            } else {
                Section("\(coordinator.selectedProvider.displayName) API key") {
                    apiKeySection
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var apiKeySection: some View {
        if apiKeyUI.hasStoredKey && !apiKeyUI.isEditing {
            if apiKeyUI.isViewingSecret {
                Text(apiKey)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("••••••••••••••••")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(apiKeyUI.isViewingSecret ? "Hide" : "View") { toggleViewMode() }
                Button("Edit") { enterEditMode() }
                Button("Clear", role: .destructive) { clearAPIKey() }
            }
        } else {
            SecureField("Enter API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save") { saveAPIKey() }
                    .buttonStyle(.borderedProminent)

                if apiKeyUI.hasStoredKey {
                    Button("Cancel") { cancelEdit() }
                    Button("Clear", role: .destructive) { clearAPIKey() }
                }
            }
        }
    }

    @ViewBuilder
    private var chatGPTAuthSection: some View {
        if coordinator.chatGPTAuthManager.isSignedIn {
            LabeledContent("Status") {
                if let hint = coordinator.chatGPTAuthManager.accountHint, !hint.isEmpty {
                    Text("Session active (\(hint))")
                } else {
                    Text("Signed in")
                }
            }
            Button("Sign out") {
                coordinator.chatGPTAuthManager.signOut()
                coordinator.refreshLLMAfterChatGPTAuth()
                chatGPTAuthUIVersion += 1
            }
        } else {
            Text("Sign in with your ChatGPT account (OAuth).")
                .foregroundStyle(.secondary)
            Button("Sign in with ChatGPT") {
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
            } footer: {
                Text(coordinator.selectedSpeechEngine == .whisper
                    ? "WhisperKit runs on-device for both microphone and system audio, with on-demand model downloads."
                    : "Parakeet transcribes microphone + system audio (FluidAudio).")
            }

            switch coordinator.selectedSpeechEngine {
            case .whisper:
                Section {
                    ForEach(LocalWhisperService.availableModelNames, id: \.self) { name in
                        whisperModelRow(for: name)
                    }
                } header: {
                    Text("Whisper model")
                } footer: {
                    Text("Models are downloaded on demand to app-scoped storage.")
                }
            case .parakeet:
                Section {
                    Picker("Model", selection: $coordinator.selectedParakeetModelChoice) {
                        ForEach(ParakeetModelChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Parakeet model")
                } footer: {
                    Text("Models run locally via FluidAudio.")
                }
            }

            Section("Audio input") {
                Picker("Input device", selection: $selectedDeviceID) {
                    Text("Select Device").tag(AudioDeviceID(0))
                    ForEach(audioDeviceService.inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceID) { _, newValue in
                    setInputDevice(newValue)
                }

                if let currentDevice = audioDeviceService.getDefaultInputDevice() {
                    LabeledContent("Current", value: currentDevice.name)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func whisperModelRow(for name: String) -> some View {
        let isDownloaded = downloadedModels.contains(name)
        let isSelected = whisperModelID == name
        let sizeText = isDownloaded
            ? modelSizes[name]
            : LocalWhisperService.estimatedSizeString(for: name).map { "~\($0)" }

        LabeledContent {
            if isDownloaded {
                Button(isSelected ? "Using" : "Use") {
                    selectWhisperModel(name)
                }
                .disabled(isSelected)
            } else {
                Button {
                    downloadModel(named: name)
                } label: {
                    if downloadingModelName == name {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading…")
                        }
                    } else {
                        Text("Download")
                    }
                }
                .disabled(downloadingModelName != nil)
            }
        } label: {
            Text(name)
            if let sizeText {
                Text(sizeText)
            }
        }
    }

    // MARK: - General tab

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Include overlay in screenshots", isOn: $coordinator.showOverlay)
            } footer: {
                Text("When off, sniff's overlays stay invisible in screen shares and captures.")
            }
        }
        .formStyle(.grouped)
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
        guard !apiKey.isEmpty else {
            showAlert("API key cannot be empty")
            return
        }

        do {
            try keychainService.saveAPIKey(apiKey, for: coordinator.selectedProvider)
            coordinator.updateAPIKey(apiKey, for: coordinator.selectedProvider)
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

    // MARK: - Whisper Model Management

    private func loadWhisperModelSelection() {
        let storedModelID = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperModelId) ?? ""
        if storedModelID.isEmpty {
            whisperModelID = LocalWhisperService.defaultModelID()
        } else {
            whisperModelID = LocalWhisperService.normalizedModelID(from: storedModelID)
        }
    }

    private func selectWhisperModel(_ name: String) {
        let normalized = LocalWhisperService.normalizedModelID(from: name)
        guard LocalWhisperService.availableModelNames.contains(normalized) else {
            showAlert("Invalid Whisper model selection")
            return
        }
        UserDefaults.standard.set(normalized, forKey: UserDefaultsKeys.whisperModelId)
        whisperModelID = normalized
    }

    private func listDownloadedModels() {
        downloadedModels = LocalWhisperService.listDownloadedModels()
        var sizes: [String: String] = [:]
        for model in downloadedModels {
            if let size = LocalWhisperService.sizeStringForDownloadedModel(model) {
                sizes[model] = size
            }
        }
        modelSizes = sizes
    }

    private func downloadModel(named name: String) {
        downloadingModelName = name

        Task {
            do {
                _ = try await LocalWhisperService.downloadModel(named: name)

                await MainActor.run {
                    downloadingModelName = nil
                    listDownloadedModels()
                    selectWhisperModel(name)
                }
            } catch {
                await MainActor.run {
                    downloadingModelName = nil
                    showAlert("Failed to download model: \(error.localizedDescription)")
                }
            }
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
