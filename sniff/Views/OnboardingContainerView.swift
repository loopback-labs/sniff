//
//  OnboardingContainerView.swift
//  sniff
//

import SwiftUI

/// Hosts the two-step onboarding flow: permissions first, then transcription-model setup.
/// Switches steps reactively as `AppPermissions.allGranted` changes, so a permission granted
/// from System Settings while this window is open advances straight to the model step.
struct OnboardingContainerView: View {
  @ObservedObject var coordinator: AppCoordinator
  var onFinish: () -> Void

  var body: some View {
    if coordinator.appPermissions.allGranted {
      TranscriptionModelOnboardingView(coordinator: coordinator, onFinish: onFinish)
    } else {
      PermissionOnboardingView(permissions: coordinator.appPermissions)
    }
  }
}
