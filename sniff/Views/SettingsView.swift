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

    private func whisperModelDisplayName(name: String, sizeText: String?) -> String {
        if let sizeText {
            return "\(name) (\(sizeText))"
        }
        return name
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Settings")
                    .font(.title2)
                    .bold()
                
                VStack(alignment: .leading, spacing: 16) {
                    SettingsFormSection(title: "LLM Provider") {
                        Picker("Provider", selection: $coordinator.selectedProvider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: coordinator.selectedProvider) { _, _ in
                            loadAPIKey()
                        }
                    }

                    SettingsFormSection(
                        title: "Model",
                        caption: "Screen questions require a vision-capable model for this provider."
                    ) {
                        Picker("Model", selection: $coordinator.selectedModelId) {
                            ForEach(LLMModelCatalog.models(for: coordinator.selectedProvider)) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if coordinator.selectedProvider.usesOAuth {
                            chatGPTAuthSection
                                .id(chatGPTAuthUIVersion)
                        } else {
                            Text("\(coordinator.selectedProvider.displayName) API Key")
                                .font(.headline)

                            if apiKeyUI.hasStoredKey && !apiKeyUI.isEditing {
                                Group {
                                    if apiKeyUI.isViewingSecret {
                                        Text(apiKey)
                                            .font(.system(.body, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(8)
                                            .background(Color(nsColor: .textBackgroundColor))
                                            .cornerRadius(6)
                                    } else {
                                        Text("••••••••••••••••")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(8)
                                    }
                                }

                                HStack {
                                    Button(apiKeyUI.isViewingSecret ? "Hide" : "View") { toggleViewMode() }
                                        .buttonStyle(.bordered)

                                    Button("Edit") { enterEditMode() }
                                        .buttonStyle(.bordered)

                                    Button("Clear") { clearAPIKey() }
                                        .buttonStyle(.bordered)
                                }
                            } else {
                                SecureField("Enter API Key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)

                                HStack {
                                    Button("Save") { saveAPIKey() }
                                        .buttonStyle(.borderedProminent)

                                    if apiKeyUI.hasStoredKey {
                                        Button("Cancel") { cancelEdit() }
                                            .buttonStyle(.bordered)

                                        Button("Clear") { clearAPIKey() }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    SettingsFormSection(
                        title: "Speech Engine",
                        caption: coordinator.selectedSpeechEngine == .whisper
                            ? "WhisperKit runs on-device for both microphone and system audio, with on-demand model downloads."
                            : "Parakeet transcribes microphone + system audio (FluidAudio)."
                    ) {
                        Picker("Speech Engine", selection: $coordinator.selectedSpeechEngine) {
                            ForEach(SpeechEngine.allCases) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Group {
                        switch coordinator.selectedSpeechEngine {
                        case .whisper:
                            whisperSettingsSection
                        case .parakeet:
                            parakeetSettingsSection
                        }
                    }

                    Divider()

                    SettingsFormSection(title: "Display") {
                        Toggle("Include Overlay in Screenshots", isOn: $coordinator.showOverlay)
                    }

                    Divider()

                    SettingsFormSection(title: "Audio Input") {
                        Picker("Input Device", selection: $selectedDeviceID) {
                            Text("Select Device").tag(AudioDeviceID(0))
                            ForEach(audioDeviceService.inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .onChange(of: selectedDeviceID) { _, newValue in
                            setInputDevice(newValue)
                        }

                        if let currentDevice = audioDeviceService.getDefaultInputDevice() {
                            Text("Current: \(currentDevice.name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadAPIKey()
            loadSelectedDevice()
            loadWhisperPaths()
            listDownloadedModels()
        }
        .alert("Settings", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    // MARK: - Whisper Settings Section
    
    @ViewBuilder
    private var whisperSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whisper Model")
                .font(.subheadline)
                .padding(.top, 4)
            
            ForEach(LocalWhisperService.availableModelNames, id: \.self) { name in
                modelRow(for: name)
            }
            
            HStack {
                Button("Save Model") { saveWhisperPaths() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)

            Text("Models are downloaded on demand to app-scoped storage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Parakeet Settings Section

    @ViewBuilder
    private var parakeetSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Parakeet Model")
                .font(.subheadline)
            
            Picker("Parakeet Model", selection: $coordinator.selectedParakeetModelChoice) {
                ForEach(ParakeetModelChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            
            Text("Models run locally via FluidAudio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private func modelRow(for name: String) -> some View {
        let isDownloaded = downloadedModels.contains(name)
        let isSelected = whisperModelID == name
        
        HStack {
            let sizeText = isDownloaded
                ? modelSizes[name]
                : LocalWhisperService.estimatedSizeString(for: name).map { "~\($0)" }

            Text(whisperModelDisplayName(name: name, sizeText: sizeText))
                .font(.caption)
            
            Spacer()
            
            if isDownloaded {
                Button(isSelected ? "Using" : "Use") {
                    whisperModelID = name
                    saveWhisperPaths()
                }
                .buttonStyle(.bordered)
                .disabled(isSelected)
            } else {
                Button(downloadingModelName == name ? "Downloading..." : "Download") {
                    downloadModel(named: name)
                }
                .buttonStyle(.bordered)
                .disabled(downloadingModelName != nil)
            }
        }
    }
    
    // MARK: - ChatGPT OAuth

    @ViewBuilder
    private var chatGPTAuthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ChatGPT account")
                .font(.headline)
            if coordinator.chatGPTAuthManager.isSignedIn {
                if let hint = coordinator.chatGPTAuthManager.accountHint, !hint.isEmpty {
                    Text("Session active (\(hint))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Signed in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Sign out") {
                    coordinator.chatGPTAuthManager.signOut()
                    coordinator.refreshLLMAfterChatGPTAuth()
                    chatGPTAuthUIVersion += 1
                    showAlert("Signed out")
                }
                .buttonStyle(.bordered)
            } else {
                Text("Sign in with your ChatGPT account (OAuth).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Sign in with ChatGPT") {
                    Task {
                        do {
                            try await coordinator.chatGPTAuthManager.signInWithBrowser()
                            await MainActor.run {
                                coordinator.refreshLLMAfterChatGPTAuth()
                                chatGPTAuthUIVersion += 1
                                showAlert("Signed in successfully")
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
            showAlert("API key saved successfully")
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
            showAlert("API key cleared")
        } catch {
            showAlert("Failed to clear API key: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Whisper Model Management
    
    private func loadWhisperPaths() {
        let storedModelID = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperModelId) ?? ""
        if storedModelID.isEmpty {
            whisperModelID = LocalWhisperService.defaultModelID()
        } else {
            whisperModelID = LocalWhisperService.normalizedModelID(from: storedModelID)
        }
    }
    
    private func saveWhisperPaths() {
        let normalized = LocalWhisperService.normalizedModelID(from: whisperModelID)
        guard LocalWhisperService.availableModelNames.contains(normalized) else {
            showAlert("Invalid Whisper model selection")
            return
        }
        UserDefaults.standard.set(normalized, forKey: UserDefaultsKeys.whisperModelId)
        whisperModelID = normalized
        showAlert("Whisper model saved")
    }
    
    // MARK: - Model Management
    
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
                    whisperModelID = name
                    saveWhisperPaths()
                    showAlert("Downloaded \(name) model")
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

// MARK: - Subviews / state

private struct SettingsFormSection<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct APIKeyUIState {
    var hasStoredKey = false
    var isEditing = false
    var isViewingSecret = false
}

#Preview("Settings") {
    SettingsView()
        .environmentObject(AppCoordinator())
        .frame(width: 520, height: 700)
}
