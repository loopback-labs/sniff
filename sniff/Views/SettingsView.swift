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
    @State private var isEditingAPIKey = false
    @State private var hasStoredAPIKey = false
    @State private var isViewingAPIKey = false
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var whisperModelID: String = LocalWhisperService.defaultModelID()
    @State private var downloadedModels: [String] = []
    @State private var downloadingModelName: String?
    @State private var modelSizes: [String: String] = [:]
    /// Bumps to refresh ChatGPT auth UI when session changes.
    @State private var chatGPTAuthUIVersion = 0
    private let keychainService = KeychainService()
    
    private var audioDeviceService: AudioDeviceService { coordinator.audioDeviceService }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Settings")
                    .font(.title2)
                    .bold()
                
                VStack(alignment: .leading, spacing: 16) {
                    // MARK: - LLM Provider
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LLM Provider")
                            .font(.headline)
                        
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

                    // MARK: - LLM Model
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model")
                            .font(.headline)
                        Picker("Model", selection: $coordinator.selectedModelId) {
                            ForEach(LLMModelCatalog.models(for: coordinator.selectedProvider)) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .labelsHidden()
                        Text("Screen questions require a vision-capable model for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // MARK: - API Key / ChatGPT
                    VStack(alignment: .leading, spacing: 8) {
                        if coordinator.selectedProvider == .chatgpt {
                            chatGPTAuthSection
                                .id(chatGPTAuthUIVersion)
                        } else {
                        Text("\(coordinator.selectedProvider.displayName) API Key")
                            .font(.headline)

                        if hasStoredAPIKey && !isEditingAPIKey {
                            Group {
                                if isViewingAPIKey {
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
                                Button(isViewingAPIKey ? "Hide" : "View") { toggleViewMode() }
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

                                if hasStoredAPIKey {
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
                    
                    // MARK: - Speech Engine
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speech Engine")
                            .font(.headline)
                        
                        Picker("Speech Engine", selection: $coordinator.selectedSpeechEngine) {
                            ForEach(SpeechEngine.allCases) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(coordinator.selectedSpeechEngine == .whisper
                             ? "WhisperKit runs on-device for both microphone and system audio, with on-demand model downloads."
                             : "Parakeet transcribes microphone + system audio (FluidAudio).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        
                        if coordinator.selectedSpeechEngine == .whisper {
                            whisperSettingsSection
                        }

                        if coordinator.selectedSpeechEngine == .parakeet {
                            parakeetSettingsSection
                        }
                    }
                    
                    Divider()
                    
                    // MARK: - Display
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display")
                            .font(.headline)
                        
                        Toggle("Include Overlay in Screenshots", isOn: $coordinator.showOverlay)
                    }
                    
                    Divider()
                    
                    // MARK: - Audio Input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Audio Input")
                            .font(.headline)
                        
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
            
            Text(sizeText == nil ? name : "\(name) (\(sizeText!))")
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
                    alertMessage = "Signed out"
                    showingAlert = true
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
                                alertMessage = "Signed in successfully"
                                showingAlert = true
                            }
                        } catch {
                            await MainActor.run {
                                alertMessage = error.localizedDescription
                                showingAlert = true
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
            hasStoredAPIKey = false
            isEditingAPIKey = false
            isViewingAPIKey = false
            return
        }
        let stored = keychainService.getAPIKey(for: coordinator.selectedProvider)
        apiKey = stored ?? ""
        hasStoredAPIKey = stored != nil && !stored!.isEmpty
        isEditingAPIKey = false
        isViewingAPIKey = false
    }

    private func enterEditMode() {
        loadAPIKey()
        isEditingAPIKey = true
        isViewingAPIKey = false
    }

    private func cancelEdit() {
        loadAPIKey()
        isEditingAPIKey = false
    }

    private func toggleViewMode() {
        if isViewingAPIKey {
            isViewingAPIKey = false
        } else {
            loadAPIKey()
            isViewingAPIKey = true
        }
    }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else {
            alertMessage = "API key cannot be empty"
            showingAlert = true
            return
        }

        do {
            try keychainService.saveAPIKey(apiKey, for: coordinator.selectedProvider)
            coordinator.updateAPIKey(apiKey, for: coordinator.selectedProvider)
            hasStoredAPIKey = true
            isEditingAPIKey = false
            alertMessage = "API key saved successfully"
            showingAlert = true
        } catch {
            alertMessage = "Failed to save API key: \(error.localizedDescription)"
            showingAlert = true
        }
    }

    private func clearAPIKey() {
        guard !coordinator.selectedProvider.usesOAuth else { return }
        do {
            try keychainService.deleteAPIKey(for: coordinator.selectedProvider)
            apiKey = ""
            hasStoredAPIKey = false
            isEditingAPIKey = false
            isViewingAPIKey = false
            coordinator.rebuildLLMService()
            alertMessage = "API key cleared"
            showingAlert = true
        } catch {
            alertMessage = "Failed to clear API key: \(error.localizedDescription)"
            showingAlert = true
        }
    }
    
    // MARK: - Whisper Model Management
    
    private func loadWhisperPaths() {
        let storedModelID = UserDefaults.standard.string(forKey: LocalWhisperService.modelSelectionKey) ?? ""
        if storedModelID.isEmpty {
            whisperModelID = LocalWhisperService.defaultModelID()
        } else {
            whisperModelID = LocalWhisperService.normalizedModelID(from: storedModelID)
        }
    }
    
    private func saveWhisperPaths() {
        let normalized = LocalWhisperService.normalizedModelID(from: whisperModelID)
        guard LocalWhisperService.availableModelNames.contains(normalized) else {
            alertMessage = "Invalid Whisper model selection"
            showingAlert = true
            return
        }
        UserDefaults.standard.set(normalized, forKey: LocalWhisperService.modelSelectionKey)
        whisperModelID = normalized
        alertMessage = "Whisper model saved"
        showingAlert = true
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
                    alertMessage = "Downloaded \(name) model"
                    showingAlert = true
                }
            } catch {
                await MainActor.run {
                    downloadingModelName = nil
                    alertMessage = "Failed to download model: \(error.localizedDescription)"
                    showingAlert = true
                }
            }
        }
    }
    
    // MARK: - Audio Device Management
    
    private func loadSelectedDevice() {
        if let savedUID = UserDefaults.standard.string(forKey: "selectedAudioInputDeviceUID"),
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
                UserDefaults.standard.set(device.uid, forKey: "selectedAudioInputDeviceUID")
            }
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }
}

#Preview("Settings") {
    SettingsView()
        .environmentObject(AppCoordinator())
        .frame(width: 520, height: 700)
}
