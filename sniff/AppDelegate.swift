//
//  AppDelegate.swift
//  sniff

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static weak var coordinator: AppCoordinator?
  private var appActivationObserver: (any NSObjectProtocol)?

  static func registerCoordinator(_ coordinator: AppCoordinator) {
    Self.coordinator = coordinator
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    Task { @MainActor in
      await AppDelegate.coordinator?.evaluatePermissionOnboardingAtLaunch()
    }

    // Recheck permissions whenever ANY app becomes active.
    // This reliably catches the case where the user returns from System Settings
    // after enabling the Screen & System Audio Recording toggle, which does not
    // always trigger applicationDidBecomeActive for LSUIElement apps.
    appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.recheckPermissionsIfNeeded()
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    recheckPermissionsIfNeeded()
  }

  private func recheckPermissionsIfNeeded() {
    guard let coordinator = AppDelegate.coordinator else { return }
    if coordinator.appPermissions.allGranted {
      if let token = appActivationObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        appActivationObserver = nil
      }
      return
    }
    Task { @MainActor in
      await coordinator.appPermissions.refreshAccurate()
      coordinator.dismissPermissionOnboardingIfAllGranted()
    }
  }
}
