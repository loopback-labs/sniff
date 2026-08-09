import SwiftUI

import CoreAudio
import AppKit

struct SettingsView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var showingAlert = false
    @State private var alertMessage = ""

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
            LLMSetupSections(coordinator: coordinator)
        }
        .formStyle(.grouped)
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

#Preview("Settings") {
    SettingsView()
        .environmentObject(AppCoordinator())
}
