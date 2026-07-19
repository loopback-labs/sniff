//
//  sniffApp.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

@main
struct sniffApp: App {
    @StateObject private var coordinator: AppCoordinator
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let coord = AppCoordinator()
        _coordinator = StateObject(wrappedValue: coord)
        AppDelegate.registerCoordinator(coord)
    }
    
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

            Button("Say Next (⌘⇧S)") {
                coordinator.runMode(.sayNext)
            }
            .disabled(!coordinator.isRunning)

            Button("Follow-ups (⌘⇧F)") {
                coordinator.runMode(.followUps)
            }
            .disabled(!coordinator.isRunning)

            Button("Recap (⌘⇧E)") {
                coordinator.runMode(.recap)
            }
            .disabled(!coordinator.isRunning)

            Button("Ask... (⌘⇧K)") {
                coordinator.focusAskComposer()
            }
            .disabled(!coordinator.isRunning)

            Button("Overlay Clicks (⌘⇧I)") {
                coordinator.overlaysForceInteractive.toggle()
            }
            .disabled(!coordinator.isRunning)

            Divider()
            
            Button("Settings...") {
                coordinator.showSettingsWindow()
            }
            
            Button("Quit (⌘⇧R)") {
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

