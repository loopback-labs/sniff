//
//  SettingsView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI
import CoreAudio

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var apiKey: String = ""
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var showingAlert = false
    @State private var alertMessage = ""
    private let keychainService = KeychainService()
    
    private var audioDeviceService: AudioDeviceService { coordinator.audioDeviceService }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.title2)
                .bold()
            
            VStack(alignment: .leading, spacing: 16) {
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
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(coordinator.selectedProvider.displayName) API Key")
                        .font(.headline)
                    
                    SecureField("Enter API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        Button("Save") {
                            saveAPIKey()
                        }
                        .buttonStyle(.borderedProminent)
                        
                        Button("Clear") {
                            clearAPIKey()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Display")
                        .font(.headline)
                    
                    Toggle("Include Overlay in Screenshots", isOn: $coordinator.showOverlay)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Audio Input")
                        .font(.headline)
                    
                    Picker("Input Device", selection: $selectedDeviceID) {
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
