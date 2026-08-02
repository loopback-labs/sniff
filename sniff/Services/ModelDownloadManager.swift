//
//  ModelDownloadManager.swift
//  sniff
//

import Combine
import Foundation

/// What a download is currently doing. Drives the row's caption text.
enum ModelDownloadPhase: Equatable {
  case preparing
  case downloading(completedFiles: Int, totalFiles: Int)

  var caption: String {
    switch self {
    case .preparing:
      return "Preparing…"
    case .downloading(let completed, let total):
      guard total > 0 else { return "Downloading…" }
      return "Downloading \(completed) of \(total) files"
    }
  }
}

struct ModelDownloadProgress: Equatable {
  var fraction: Double
  var phase: ModelDownloadPhase
}

/// Owns every on-device speech model download, app-wide.
///
/// Download state deliberately lives here rather than in the model-list views: a `TabView` tears
/// its inactive tab's content down, which used to reset the row's `@State` and lose the running
/// download's progress, its dedupe guard, and any error it later hit — the download kept going
/// invisibly while the UI claimed it had never started. Holding it on the coordinator means
/// progress survives tab switches, window closes, and the whole Settings/onboarding split.
@MainActor
final class ModelDownloadManager: ObservableObject {
  @Published private(set) var progress: [SpeechModel: ModelDownloadProgress] = [:]
  @Published private(set) var installed: Set<SpeechModel> = []
  @Published private(set) var installedSizes: [SpeechModel: String] = [:]
  @Published private(set) var failures: [SpeechModel: String] = [:]

  private var tasks: [SpeechModel: Task<Void, Never>] = [:]

  init() {
    refreshInstalled()
  }

  // MARK: - Queries

  func isDownloading(_ model: SpeechModel) -> Bool {
    tasks[model] != nil
  }

  func isInstalled(_ model: SpeechModel) -> Bool {
    installed.contains(model)
  }

  /// Active downloads in a stable order, so the status bar doesn't reshuffle between updates.
  var activeDownloads: [SpeechModel] {
    let engines: [SpeechEngine] = [.whisper, .parakeet]
    return engines
      .flatMap { SpeechModel.all(for: $0) }
      .filter { tasks[$0] != nil }
  }

  var hasActiveDownloads: Bool {
    !tasks.isEmpty
  }

  // MARK: - Installed state

  func refreshInstalled() {
    var nextInstalled: Set<SpeechModel> = []
    var nextSizes: [SpeechModel: String] = [:]

    let downloadedWhisper = Set(LocalWhisperService.listDownloadedModels())
    for name in LocalWhisperService.availableModelNames where downloadedWhisper.contains(name) {
      let model = SpeechModel.whisper(name)
      nextInstalled.insert(model)
      nextSizes[model] = LocalWhisperService.sizeStringForDownloadedModel(name)
    }

    for choice in ParakeetModelChoice.allCases where ParakeetTranscriptionService.isDownloaded(choice) {
      let model = SpeechModel.parakeet(choice)
      nextInstalled.insert(model)
      nextSizes[model] = ParakeetTranscriptionService.sizeStringForDownloadedModel(choice)
    }

    // Recomputed wholesale rather than merged, so a model deleted on disk actually disappears.
    installed = nextInstalled
    installedSizes = nextSizes.compactMapValues { $0 }
  }

  /// Total bytes of every installed model, for the storage row in Settings.
  func totalInstalledSizeString() -> String? {
    let directories = [
      LocalWhisperService.modelStorageDirectory(),
      ParakeetTranscriptionService.modelStorageDirectory(),
    ]
    let total = directories.compactMap { Self.directorySizeInBytes(at: $0) }.reduce(0, +)
    guard total > 0 else { return nil }
    return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
  }

  // MARK: - Mutations

  /// Starts a download, or does nothing if one is already in flight for this model. The dedupe
  /// lives here (not in a view) so a tab switch can't produce a second concurrent download.
  func download(_ model: SpeechModel) {
    guard tasks[model] == nil else { return }

    failures[model] = nil
    progress[model] = ModelDownloadProgress(fraction: 0, phase: .preparing)

    let task = Task { [weak self] in
      let handler: @Sendable (Double, Int, Int) -> Void = { fraction, completed, total in
        Task { @MainActor [weak self] in
          self?.updateProgress(model, fraction: fraction, completedFiles: completed, totalFiles: total)
        }
      }

      do {
        switch model {
        case .whisper(let name):
          _ = try await LocalWhisperService.downloadModel(named: name, progressHandler: handler)
        case .parakeet(let choice):
          try await ParakeetTranscriptionService.downloadModel(choice, progressHandler: handler)
        }
        await MainActor.run { self?.finish(model, error: nil) }
      } catch is CancellationError {
        await MainActor.run { self?.finish(model, error: nil) }
      } catch {
        await MainActor.run { self?.finish(model, error: error) }
      }
    }

    tasks[model] = task
  }

  /// Stops waiting on a download. Whisper models come down on a background `URLSession`, so bytes
  /// already in flight may still land on disk — a later re-download then resumes rather than
  /// starting over, which is the behaviour we want anyway.
  func cancel(_ model: SpeechModel) {
    tasks[model]?.cancel()
    tasks[model] = nil
    progress[model] = nil
    refreshInstalled()
  }

  func delete(_ model: SpeechModel) {
    guard tasks[model] == nil else { return }
    do {
      switch model {
      case .whisper(let name):
        try LocalWhisperService.deleteModel(named: name)
      case .parakeet(let choice):
        try ParakeetTranscriptionService.deleteModel(choice)
      }
      failures[model] = nil
    } catch {
      failures[model] = "Couldn't remove this model: \(error.localizedDescription)"
    }
    refreshInstalled()
  }

  func dismissFailure(for model: SpeechModel) {
    failures[model] = nil
  }

  // MARK: - Internals

  private func updateProgress(_ model: SpeechModel, fraction: Double, completedFiles: Int, totalFiles: Int) {
    guard tasks[model] != nil else { return }
    progress[model] = ModelDownloadProgress(
      fraction: min(max(fraction, 0), 1),
      phase: totalFiles > 0
        ? .downloading(completedFiles: completedFiles, totalFiles: totalFiles)
        : .preparing
    )
  }

  private func finish(_ model: SpeechModel, error: Error?) {
    // `cancel` already cleared the entry, so a late error from a download the user stopped is
    // dropped rather than surfaced as a failure they didn't cause.
    let wasCancelled = tasks[model] == nil

    tasks[model] = nil
    progress[model] = nil
    // Errors are stored, not thrown at an alert: an alert bound to a torn-down view never shows,
    // which is how failed downloads used to vanish silently.
    if let error, !wasCancelled {
      failures[model] = error.localizedDescription
    }
    refreshInstalled()
  }

  private static func directorySizeInBytes(at url: URL) -> Int64? {
    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(
        forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
      ) else { continue }
      guard values.isRegularFile == true else { continue }
      if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
        total += Int64(allocated)
      }
    }
    return total
  }
}
