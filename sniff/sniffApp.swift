//
//  sniffApp.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI
// import AppKit

@main
struct sniffApp: App {
    @StateObject private var coordinator = AppCoordinator()
    
    var body: some Scene {
        MenuBarExtra("Sniff", systemImage: "questionmark.bubble") {
            MenuBarView()
                .environmentObject(coordinator)
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            SettingsView()
                .environmentObject(coordinator)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                Task {
                    if coordinator.isRunning {
                        await coordinator.stop()
                    } else {
                        await coordinator.start()
                    }
                }
            }) {
                HStack {
                    Image(systemName: coordinator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    Text(coordinator.isRunning ? "Stop (⌘⇧W)" : "Start (⌘⇧W)")
                }
            }
            
            Toggle("Automatic Mode (⌘⇧M)", isOn: $coordinator.automaticMode)
                .disabled(!coordinator.isRunning)
            
            Divider()
            
            Button("Screen Question (⌘⇧Q)") {
                coordinator.triggerScreenQuestion()
            }
            .disabled(!coordinator.isRunning)
            
            Button("Audio Question (⌘⇧A)") {
                coordinator.triggerAudioQuestion()
            }
            .disabled(!coordinator.isRunning)
            
            Divider()
            
            Button("Settings...") {
                coordinator.showSettingsWindow()
            }
            
            Button("Quit") {
                Task {
                    await coordinator.stop()
                    await MainActor.run {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .padding()
        .frame(width: 200)
    }
}

