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
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var whisperBinaryPath: String = ""
    @State private var whisperModelPath: String = ""
    @State private var downloadedModels: [String] = []
    @State private var downloadingModelName: String?
    @State private var modelSizes: [String: String] = [:]
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
                        .pickerStyle(.segmented)
                        .onChange(of: coordinator.selectedProvider) { _, _ in
                            loadAPIKey()
                        }
                    }
                    
                    // MARK: - API Key
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(coordinator.selectedProvider.displayName) API Key")
                            .font(.headline)
                        
                        SecureField("Enter API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        
                        HStack {
                            Button("Save") { saveAPIKey() }
                                .buttonStyle(.borderedProminent)
                            
                            Button("Clear") { clearAPIKey() }
                                .buttonStyle(.bordered)
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
                        
                        if coordinator.selectedSpeechEngine == .whisper {
                            whisperSettingsSection
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
            Text("Whisper Binary")
                .font(.subheadline)
            
            HStack {
                TextField("Path to whisper-stream", text: $whisperBinaryPath)
                    .textFieldStyle(.roundedBorder)
                
                Button("Browse") { chooseWhisperBinary() }
                    .buttonStyle(.bordered)
            }
            
            if !whisperBinaryPath.isEmpty {
                let isValid = LocalWhisperService.validateBinaryPath(whisperBinaryPath)
                HStack {
                    Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(isValid ? .green : .red)
                    Text(isValid ? "Binary found" : "Binary not found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Text("Whisper Model")
                .font(.subheadline)
                .padding(.top, 4)
            
            ForEach(LocalWhisperService.availableModelNames, id: \.self) { name in
                modelRow(for: name)
            }
            
            HStack {
                Button("Test Whisper Setup") { testWhisperSetup() }
                    .buttonStyle(.borderedProminent)
                
                Button("Save Paths") { saveWhisperPaths() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
            
            Text("Install via: brew install whisper-cpp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private func modelRow(for name: String) -> some View {
        let filename = "ggml-\(name).bin"
        let isDownloaded = downloadedModels.contains(filename)
        let isSelected = whisperModelPath.hasSuffix(filename)
        
        HStack {
            let sizeText = isDownloaded
                ? modelSizes[filename]
                : LocalWhisperService.estimatedSizeString(for: name).map { "~\($0)" }
            
            Text(sizeText == nil ? name : "\(name) (\(sizeText!))")
                .font(.caption)
            
            Spacer()
            
            if isDownloaded {
                Button(isSelected ? "Using" : "Use") {
                    whisperModelPath = LocalWhisperService.modelURL(for: name).path
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
    
    // MARK: - API Key Management
    
    private func loadAPIKey() {
        apiKey = keychainService.getAPIKey(for: coordinator.selectedProvider) ?? ""
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
            alertMessage = "API key saved successfully"
            showingAlert = true
        } catch {
            alertMessage = "Failed to save API key: \(error.localizedDescription)"
            showingAlert = true
        }
    }
    
    private func clearAPIKey() {
        do {
            try keychainService.deleteAPIKey(for: coordinator.selectedProvider)
            apiKey = ""
            coordinator.rebuildLLMService()
            alertMessage = "API key cleared"
            showingAlert = true
        } catch {
            alertMessage = "Failed to clear API key: \(error.localizedDescription)"
            showingAlert = true
        }
    }
    
    // MARK: - Whisper Path Management
    
    private func loadWhisperPaths() {
        // Load stored paths or auto-detect
        let storedBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath") ?? ""
        let storedModelPath = UserDefaults.standard.string(forKey: "whisperModelPath") ?? ""
        
        // Use stored path if valid, otherwise auto-detect
        if !storedBinaryPath.isEmpty && LocalWhisperService.validateBinaryPath(storedBinaryPath) {
            whisperBinaryPath = storedBinaryPath
        } else if let detected = LocalWhisperService.detectBinaryPath() {
            whisperBinaryPath = detected
        }
        
        // Use stored model path if exists, otherwise use default
        if !storedModelPath.isEmpty && FileManager.default.fileExists(atPath: storedModelPath) {
            whisperModelPath = storedModelPath
        } else {
            whisperModelPath = LocalWhisperService.defaultModelPath()
        }
    }
    
    private func saveWhisperPaths() {
        guard !whisperBinaryPath.isEmpty else {
            alertMessage = "Whisper binary path cannot be empty"
            showingAlert = true
            return
        }
        
        UserDefaults.standard.set(whisperBinaryPath, forKey: "whisperBinaryPath")
        UserDefaults.standard.set(whisperModelPath, forKey: "whisperModelPath")
        alertMessage = "Whisper paths saved"
        showingAlert = true
    }
    
    private func chooseWhisperBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Select whisper-stream binary"
        
        // Start in a sensible directory
        if !whisperBinaryPath.isEmpty {
            let url = URL(fileURLWithPath: (whisperBinaryPath as NSString).expandingTildeInPath)
            panel.directoryURL = url.deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            whisperBinaryPath = url.path
        }
    }
    
    private func testWhisperSetup() {
        guard !whisperBinaryPath.isEmpty else {
            alertMessage = "Please set the whisper binary path first"
            showingAlert = true
            return
        }
        
        do {
            try LocalWhisperService.testBinary(at: whisperBinaryPath)
            alertMessage = "Whisper binary OK!"
            showingAlert = true
        } catch {
            alertMessage = error.localizedDescription
            showingAlert = true
        }
    }
    
    // MARK: - Model Management
    
    private func listDownloadedModels() {
        downloadedModels = LocalWhisperService.listDownloadedModels()
        var sizes: [String: String] = [:]
        for model in downloadedModels {
            if let size = LocalWhisperService.sizeStringForModelFile(model) {
                sizes[model] = size
            }
        }
        modelSizes = sizes
    }
    
    private func downloadModel(named name: String) {
        guard let downloadURL = LocalWhisperService.downloadURL(for: name) else {
            alertMessage = "Invalid model name"
            showingAlert = true
            return
        }
        
        downloadingModelName = name
        let destination = LocalWhisperService.modelURL(for: name)
        
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                
                await MainActor.run {
                    downloadingModelName = nil
                    listDownloadedModels()
                    whisperModelPath = destination.path
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
