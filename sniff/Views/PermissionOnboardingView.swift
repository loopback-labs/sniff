//
//  PermissionOnboardingView.swift
//  sniff

import Observation
import SwiftUI

struct PermissionOnboardingView: View {
  @Bindable var permissions: AppPermissions

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Set up Sniff")
        .font(.title2.weight(.semibold))

      Text("Allow these permissions so Sniff can capture screen, system audio, and your microphone.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if permissions.screenRecordingMayNeedRelaunch {
        Text("If Screen & System Audio Recording is already allowed, quit and reopen Sniff. macOS applies that permission after relaunch.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 10) {
        ForEach(AppPermissionKind.allCases) { kind in
          permissionRow(kind)
        }
      }

      HStack {
        Spacer()

        Button("Continue") {
          Task {
            await permissions.refreshAccurate()
          }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
    .task {
      await permissions.refreshAccurate()
      while !permissions.allGranted {
        try? await Task.sleep(for: .seconds(2))
        permissions.refreshQuick()
      }
    }
  }

  @ViewBuilder
  private func permissionRow(_ kind: AppPermissionKind) -> some View {
    let granted = permissions.isGranted(kind)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .foregroundStyle(granted ? .green : .orange)
          .imageScale(.large)

        VStack(alignment: .leading, spacing: 4) {
          Text(kind.title)
            .font(.headline)
          Text(kind.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)
      }

      if !granted {
        HStack(spacing: 8) {
          if kind == .screenRecording, permissions.screenRecordingPromptRequested {
            Button("Open System Settings") {
              permissions.openSystemSettings(for: kind)
            }
          } else {
            Button("Allow") {
              permissions.prompt(for: kind)
            }
            Button("Settings") {
              permissions.openSystemSettings(for: kind)
            }
          }

          if kind == .screenRecording, permissions.screenRecordingMayNeedRelaunch {
            Button("Quit Sniff") {
              permissions.quitForPermissionRelaunch()
            }
          }
        }
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor))
    .cornerRadius(8)
  }
}
