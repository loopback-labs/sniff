//
//  AppPermissions.swift
//  sniff

import AppKit
import ApplicationServices
import AVFAudio
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

// IOHIDCheckAccess(IOHIDRequestType) — not in Swift IOKit overlay; used to detect Input Monitoring
// when global shortcuts work but AXIsProcessTrusted is still false.
@_silgen_name("IOHIDCheckAccess")
private func _ioHIDCheckAccess(_ requestType: UInt32) -> UInt32

private enum IOHIDRequestType: UInt32 {
  case listenEvent = 1 // kIOHIDRequestTypeListenEvent
}

private enum IOHIDAccessType: UInt32 {
  case granted = 0 // kIOHIDAccessTypeGranted
}

enum AppPermissionKind: String, CaseIterable, Identifiable {
  case screenRecording
  case microphone

  var id: String { rawValue }

  var title: String {
    switch self {
    case .screenRecording:
      return "Screen & System Audio Recording"
    case .microphone:
      return "Microphone"
    }
  }

  var detail: String {
    switch self {
    case .screenRecording:
      return "Allow Sniff to read screen content and capture system audio."
    case .microphone:
      return "Allow Sniff to capture your voice for transcription."
    }
  }

  var settingsURL: URL {
    switch self {
    case .screenRecording:
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    case .microphone:
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    }
  }
}

@MainActor
@Observable
final class AppPermissions {
  private(set) var screenRecordingGranted = false
  private(set) var microphoneGranted = false
  private(set) var accessibilityGranted = false
  private(set) var screenRecordingPromptRequested = UserDefaults.standard.bool(
    forKey: UserDefaultsKeys.screenRecordingPromptRequested
  )

  var allGranted: Bool {
    screenRecordingGranted && microphoneGranted
  }

  var screenRecordingMayNeedRelaunch: Bool {
    screenRecordingPromptRequested && !screenRecordingGranted
  }

  // Lightweight check — only CGPreflightScreenCaptureAccess, no SCK call.
  // Safe to call frequently from a polling loop without risk of triggering system dialogs.
  func refreshQuick() {
    microphoneGranted = Self.microphoneGrantedSnapshot()
    let preflight = CGPreflightScreenCaptureAccess()
    if preflight {
      screenRecordingGranted = true
    }
    // Don't set screenRecordingGranted = false here; a previous accurate
    // check may have detected it via SCK and we don't want to regress.
  }

  // Full check — also probes ScreenCaptureKit when CGPreflight returns false.
  // Only call on explicit user actions (button taps, app activation), not in a tight loop.
  func refreshAccurate() async {
    microphoneGranted = Self.microphoneGrantedSnapshot()
    accessibilityGranted = Self.globalShortcutsPermissionSnapshot()

    if CGPreflightScreenCaptureAccess() {
      screenRecordingGranted = true
      // Persist that permission was ever granted so the SCK fallback fires
      // on future launches where TCC hasn't warmed up yet.
      if !screenRecordingPromptRequested {
        screenRecordingPromptRequested = true
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.screenRecordingPromptRequested)
      }
      return
    }

    // CGPreflightScreenCaptureAccess can return false until the TCC daemon
    // propagates the change. Fall back to an SCK probe, but only after the
    // user has started the permission flow (to avoid triggering a first-time
    // system dialog from a background refresh).
    if screenRecordingPromptRequested {
      screenRecordingGranted = await Self.probeScreenCaptureWithShareableContent()
    } else {
      screenRecordingGranted = false
    }
  }

  private static func microphoneGrantedSnapshot() -> Bool {
    AVAudioApplication.shared.recordPermission == .granted
  }

  /// `AXIsProcessTrusted` can lag right after launch for LSUIElement apps; Input Monitoring also satisfies HotKey.
  private static func globalShortcutsPermissionSnapshot() -> Bool {
    if AXIsProcessTrusted() {
      return true
    }
    return _ioHIDCheckAccess(IOHIDRequestType.listenEvent.rawValue) == IOHIDAccessType.granted.rawValue
  }

  // Uses SCShareableContent.current rather than excludingDesktopWindows:
  // the latter's onScreenWindowsOnly filter can return empty results for
  // LSUIElement apps even when permission is granted.
  private nonisolated static func probeScreenCaptureWithShareableContent() async -> Bool {
    do {
      let content = try await SCShareableContent.current
      let granted = !content.displays.isEmpty
      print("[Sniff] SCK probe: displays=\(content.displays.count) granted=\(granted)")
      return granted
    } catch {
      let e = error as NSError
      // -3801 = SCStreamErrorUserDeclined (permission denied by TCC)
      print("[Sniff] SCK probe error: \(e.domain) code=\(e.code) — \(e.localizedDescription)")
      return false
    }
  }

  func promptScreenRecording() {
    screenRecordingPromptRequested = true
    UserDefaults.standard.set(true, forKey: UserDefaultsKeys.screenRecordingPromptRequested)
    _ = CGRequestScreenCaptureAccess()
    Task {
      try? await Task.sleep(for: .milliseconds(700))
      await refreshAccurate()
    }
  }

  func promptMicrophone() {
    AVAudioApplication.requestRecordPermission { [weak self] _ in
      Task { @MainActor in
        await self?.refreshAccurate()
      }
    }
  }

  func prompt(for kind: AppPermissionKind) {
    switch kind {
    case .screenRecording:
      promptScreenRecording()
    case .microphone:
      promptMicrophone()
    }
  }

  func openSystemSettings(for kind: AppPermissionKind) {
    if NSWorkspace.shared.open(kind.settingsURL) {
      return
    }

    let fallbackURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.openApplication(at: fallbackURL, configuration: configuration) { app, error in
      if let error {
        print("Failed to open System Settings for \(kind.title): \(error)")
      } else if app == nil {
        print("System Settings did not launch for \(kind.title)")
      }
    }
  }

  func quitForPermissionRelaunch() {
    NSApplication.shared.terminate(nil)
  }

  func isGranted(_ kind: AppPermissionKind) -> Bool {
    switch kind {
    case .screenRecording:
      return screenRecordingGranted
    case .microphone:
      return microphoneGranted
    }
  }
}
