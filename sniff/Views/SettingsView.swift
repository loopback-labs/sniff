//
//  SettingsView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var apiKey: String = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    private let keychainService = KeychainService()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Settings")
                .font(.title2)
                .bold()
            
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Perplexity API Key")
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
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 400, height: 350)
        .onAppear {
            loadAPIKey()
        }
        .alert("Settings", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func loadAPIKey() {
        if let key = keychainService.getAPIKey() {
            apiKey = key
        }
    }
    
    private func saveAPIKey() {
        guard !apiKey.isEmpty else {
            alertMessage = "API key cannot be empty"
            showingAlert = true
            return
        }
        
        do {
            try keychainService.saveAPIKey(apiKey)
            coordinator.updateAPIKey(apiKey)
            alertMessage = "API key saved successfully"
            showingAlert = true
        } catch {
            alertMessage = "Failed to save API key: \(error.localizedDescription)"
            showingAlert = true
        }
    }
    
    private func clearAPIKey() {
        do {
            try keychainService.deleteAPIKey()
            apiKey = ""
            alertMessage = "API key cleared"
            showingAlert = true
        } catch {
            alertMessage = "Failed to clear API key: \(error.localizedDescription)"
            showingAlert = true
        }
    }
}
