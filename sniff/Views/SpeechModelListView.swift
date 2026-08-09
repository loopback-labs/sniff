import SwiftUI


/// Download/select rows for an engine's on-device models. Shared by `SettingsView` (Speech tab)
/// and `TranscriptionModelOnboardingView` so the download UX is identical in both places.
///
/// All download state comes from `AppCoordinator.modelDownloads` rather than local `@State`, so
/// switching Settings tabs (which tears this view down) no longer loses a running download.
struct SpeechModelListView: View {
  @ObservedObject var coordinator: AppCoordinator
  // Observed directly rather than reached through `coordinator.modelDownloads`: the manager is a
  // plain `let` on the coordinator, so its `@Published` changes don't republish the coordinator
  // and progress updates would never reach this view.
  @ObservedObject var downloads: ModelDownloadManager
  let engine: SpeechEngine
  var onSelect: ((SpeechModel) -> Void)?

  init(coordinator: AppCoordinator, engine: SpeechEngine, onSelect: ((SpeechModel) -> Void)? = nil) {
    self.coordinator = coordinator
    self.downloads = coordinator.modelDownloads
    self.engine = engine
    self.onSelect = onSelect
  }

  @State private var pendingDeletion: SpeechModel?

  var body: some View {
    ForEach(SpeechModel.all(for: engine)) { model in
      SpeechModelRow(
        model: model,
        isSelected: isSelected(model),
        isInstalled: downloads.isInstalled(model),
        installedSize: downloads.installedSizes[model],
        progress: downloads.progress[model],
        failure: downloads.failures[model],
        onUse: { select(model) },
        onDownload: { downloads.download(model) },
        onCancel: { downloads.cancel(model) },
        onDelete: { pendingDeletion = model },
        onDismissFailure: { downloads.dismissFailure(for: model) }
      )
    }
    .onAppear { downloads.refreshInstalled() }
    .confirmationDialog(
      "Remove \(pendingDeletion?.displayName ?? "this model")?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        if let model = pendingDeletion { downloads.delete(model) }
        pendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("The files are deleted from disk. You can download it again at any time.")
    }
  }

  private func isSelected(_ model: SpeechModel) -> Bool {
    switch model {
    case .whisper(let name): return coordinator.selectedWhisperModelID == name
    case .parakeet(let choice): return coordinator.selectedParakeetModelChoice == choice
    }
  }

  private func select(_ model: SpeechModel) {
    switch model {
    case .whisper(let name):
      coordinator.selectedWhisperModelID = LocalWhisperService.normalizedModelID(from: name)
    case .parakeet(let choice):
      coordinator.selectedParakeetModelChoice = choice
    }
    onSelect?(model)
  }
}

// MARK: - Row

private struct SpeechModelRow: View {
  let model: SpeechModel
  let isSelected: Bool
  let isInstalled: Bool
  let installedSize: String?
  let progress: ModelDownloadProgress?
  let failure: String?

  var onUse: () -> Void
  var onDownload: () -> Void
  var onCancel: () -> Void
  var onDelete: () -> Void
  var onDismissFailure: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      statusIcon
        .frame(width: 18)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(model.displayName)
            .font(.body.weight(.medium))

          if model.isRecommended {
            Text("Recommended")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.15), in: Capsule())
              .foregroundStyle(Color.accentColor)
          }
        }

        if let progress {
          ProgressView(value: progress.fraction)
            .progressViewStyle(.linear)
            .controlSize(.small)

          Text("\(Int(progress.fraction * 100))% · \(progress.phase.caption)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else if let failure {
          Text(failure)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 8)

      trailingControls
    }
    .padding(.vertical, 4)
  }

  // Size leads so a wrapped line never strands the separator at the end of a row.
  private var subtitle: String {
    if let size = sizeText {
      return "\(size) · \(model.detail)"
    }
    return model.detail
  }

  private var sizeText: String? {
    if isInstalled { return installedSize }
    guard let bytes = model.estimatedSizeBytes else { return nil }
    return "~\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
  }

  @ViewBuilder
  private var statusIcon: some View {
    if progress != nil {
      Image(systemName: "arrow.down.circle")
        .foregroundStyle(Color.accentColor)
    } else if failure != nil {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    } else if isInstalled {
      // Selection only reads as a filled check once the model is actually on disk — a selected
      // but undownloaded model showing a check next to a "Download" button is a lie.
      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
    } else {
      Image(systemName: "arrow.down.circle.dotted")
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var trailingControls: some View {
    if progress != nil {
      Button("Stop", action: onCancel)
    } else if failure != nil {
      HStack(spacing: 6) {
        Button("Retry") {
          onDismissFailure()
          onDownload()
        }
        .buttonStyle(.borderedProminent)

        Button("Dismiss", action: onDismissFailure)
      }
    } else if isInstalled {
      HStack(spacing: 6) {
        if isSelected {
          Text("In use")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        } else {
          Button("Use", action: onUse)
        }

        Menu {
          Button("Remove Download", role: .destructive, action: onDelete)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
    } else {
      Button("Download", action: onDownload)
    }
  }
}

// MARK: - Cross-tab status bar

/// Persistent footer shown on every Settings tab while any model is downloading, so leaving the
/// Speech tab no longer means losing sight of a multi-gigabyte download.
struct ActiveDownloadsBar: View {
  @ObservedObject var downloads: ModelDownloadManager

  var body: some View {
    let active = downloads.activeDownloads
    if !active.isEmpty {
      VStack(spacing: 6) {
        ForEach(active) { model in
          let progress = downloads.progress[model]
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)

            Text(model.displayName)
              .font(.caption.weight(.medium))

            if let progress {
              ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 160)

              Text("\(Int(progress.fraction * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer(minLength: 0)

            Button("Stop") { downloads.cancel(model) }
              .controlSize(.small)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
    }
  }
}
