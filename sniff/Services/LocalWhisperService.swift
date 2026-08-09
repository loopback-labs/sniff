import Foundation
import AVFoundation
import Combine
import CoreMedia
import FluidAudio
import WhisperKit

@MainActor
final class LocalWhisperService: ObservableObject {
    @Published var micUpdate: TranscriptionUpdate = TranscriptionUpdate(text: "", isFinal: true)
    @Published var systemUpdate: TranscriptionUpdate = TranscriptionUpdate(text: "", isFinal: true)
    @Published var isCapturing: Bool = false
    /// Smoothed 0...1 microphone peak, so the UI can show that audio is actually arriving.
    @Published private(set) var micLevel: Float = 0

    static let modelSelectionKey = UserDefaultsKeys.whisperModelId

    static let availableModelNames: [String] = [
        "tiny", "small", "medium", "large-v3"
    ]

    static let estimatedModelSizes: [String: Int64] = [
        "tiny": 80_000_000,
        "small": 520_000_000,
        "medium": 1_700_000_000,
        "large-v3": 1_000_000_000
    ]

    private static let downloadedModelPathMapKey = "whisperDownloadedModelPaths"

    private let audioEngine = AVAudioEngine()
    private lazy var micSampleBridge = MicSampleBridge(label: "com.sniff.whisper.mic") { [weak self] samples in
        Task { @MainActor [weak self] in
            guard let self, self.capturingInternal else { return }
            self.micLevel = AudioLevelMeter.next(level: self.micLevel, samples: samples)
            self.micVadSegmenter.enqueue(samples)
        }
    }

    private let micVadSegmenter = VadSegmenter()
    private let systemVadSegmenter = VadSegmenter()
    private var micLastPartialTime: Date = .distantPast
    private var systemLastPartialTime: Date = .distantPast
    private let partialThrottleInterval: TimeInterval = 1.5

    private var configuredModelID: String = LocalWhisperService.defaultModelID()
    private var loadedModelVariant: String?
    private var whisperKit: WhisperKit?

    private var capturingInternal = false
    // Single-WhisperKit mutex shared by mic + system: partials check-and-drop on contention,
    // finals wait (see `waitUntilTranscriberFree`) so an utterance is never silently lost.
    private var transcriptionInFlight = false

    func configure(modelID: String) {
        let normalized = Self.normalizedModelID(from: modelID)
        configuredModelID = normalized.isEmpty ? Self.defaultModelID() : normalized
        UserDefaults.standard.set(configuredModelID, forKey: Self.modelSelectionKey)
    }

    func startCapture() async throws {
        guard !isCapturing else { return }

        capturingInternal = true
        micVadSegmenter.reset()
        systemVadSegmenter.reset()
        micLastPartialTime = .distantPast
        systemLastPartialTime = .distantPast

        do {
            try await ensureWhisperKitReady()
            wireSegmenters()
            // Start both VAD segmenters (load their model, ready their streams) before installing
            // the mic tap / accepting system audio, so no samples arrive before something is
            // listening for them.
            try await micVadSegmenter.start()
            try await systemVadSegmenter.start()
            try startMicCapture()
            isCapturing = true
        } catch {
            capturingInternal = false
            stopMicCapture()
            throw error
        }
    }

    func stopCapture(finalizeSystem: Bool) async {
        guard capturingInternal || isCapturing else { return }

        capturingInternal = false
        stopMicCapture()

        await micVadSegmenter.stop(finalizingRemainder: finalizeSystem)
        await systemVadSegmenter.stop(finalizingRemainder: finalizeSystem)

        transcriptionInFlight = false
        isCapturing = false
    }

    func appendSystemAudioFloats(_ floats: [Float]) {
        guard capturingInternal else { return }
        systemVadSegmenter.enqueue(floats)
    }

    func reset() {
        micUpdate = TranscriptionUpdate(text: "", isFinal: true)
        systemUpdate = TranscriptionUpdate(text: "", isFinal: true)
        micLevel = 0
        micVadSegmenter.reset()
        systemVadSegmenter.reset()
        micLastPartialTime = .distantPast
        systemLastPartialTime = .distantPast
    }

    private func wireSegmenters() {
        micVadSegmenter.onPartial = { [weak self] samples in
            self?.handlePartial(samples: samples, speaker: .you)
        }
        micVadSegmenter.onSegment = { [weak self] samples in
            await self?.transcribeFinal(samples: samples, speaker: .you)
        }
        systemVadSegmenter.onPartial = { [weak self] samples in
            self?.handlePartial(samples: samples, speaker: .others)
        }
        systemVadSegmenter.onSegment = { [weak self] samples in
            await self?.transcribeFinal(samples: samples, speaker: .others)
        }
    }

    private func ensureWhisperKitReady() async throws {
        let modelID = configuredModelID.isEmpty ? Self.defaultModelID() : configuredModelID
        let variant = Self.modelVariant(forModelID: modelID)

        if whisperKit != nil, loadedModelVariant == variant {
            return
        }

        let modelFolder = try await Self.downloadModel(named: modelID)
        let config = WhisperKitConfig(
            model: variant,
            modelRepo: "argmaxinc/whisperkit-coreml",
            modelFolder: modelFolder.path,
            prewarm: false,
            load: true,
            download: false,
            useBackgroundDownloadSession: true
        )
        config.logLevel = .info
        config.verbose = false

        whisperKit = try await WhisperKit(config)
        loadedModelVariant = variant
        UserDefaults.standard.set(modelID, forKey: Self.modelSelectionKey)
    }

    private func startMicCapture() throws {
        guard !audioEngine.isRunning else { return }
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LocalWhisperError.transcriptionFailed("No valid audio input device. Check microphone connection and permissions.")
        }

        inputNode.removeTap(onBus: 0)

        let bridge = micSampleBridge

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            bridge.process(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopMicCapture() {
        guard audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    /// Fires on every VAD chunk while a segment is accumulating; cheap by design (throttle + busy
    /// check, then hand off), matching `VadSegmenter.onPartial`'s non-blocking contract.
    private func handlePartial(samples: [Float], speaker: TranscriptSpeaker) {
        let now = Date()
        let lastTime = speaker == .you ? micLastPartialTime : systemLastPartialTime
        guard now.timeIntervalSince(lastTime) >= partialThrottleInterval else { return }
        guard !transcriptionInFlight else { return }

        switch speaker {
        case .you: micLastPartialTime = now
        case .others: systemLastPartialTime = now
        }

        Task { [weak self] in
            await self?.transcribePartial(samples: samples, speaker: speaker)
        }
    }

    private func transcribePartial(samples: [Float], speaker: TranscriptSpeaker) async {
        // Partials are disposable: drop on contention rather than queueing. Claiming the slot
        // happens in the same synchronous step as the check, so it can't race a concurrent final.
        guard !transcriptionInFlight else { return }
        transcriptionInFlight = true
        defer { transcriptionInFlight = false }

        do {
            let text = try await transcribe(samples: samples)
            guard !text.isEmpty else { return }
            publish(text: text, speaker: speaker, isFinal: false)
        } catch {
            print("⚠️ [WhisperKit] Partial transcription failed (\(speaker)): \(error.localizedDescription)")
        }
    }

    private func transcribeFinal(samples: [Float], speaker: TranscriptSpeaker) async {
        // Finals are never dropped: wait out any in-flight partial/final before running.
        await claimTranscriber()
        defer { transcriptionInFlight = false }

        do {
            let text = try await transcribe(samples: samples)
            publish(text: text, speaker: speaker, isFinal: true)
        } catch {
            print("⚠️ [WhisperKit] Final transcription failed (\(speaker)): \(error.localizedDescription)")
        }
    }

    /// Waits for the single shared WhisperKit instance and claims it.
    ///
    /// The claim must happen in the same synchronous step that observes the flag as free —
    /// previously the flag was only set inside `transcribe`, one `await` later, so a mic final and
    /// a system final could both clear the wait and then run `whisperKit.transcribe` concurrently
    /// on one instance.
    private func claimTranscriber() async {
        while transcriptionInFlight {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        transcriptionInFlight = true
    }

    private func publish(text: String, speaker: TranscriptSpeaker, isFinal: Bool) {
        let update = TranscriptionUpdate(text: text, isFinal: isFinal)
        switch speaker {
        case .you: micUpdate = update
        case .others: systemUpdate = update
        }
    }

    private func transcribe(samples: [Float]) async throws -> String {
        // Callers own `transcriptionInFlight` — see `claimTranscriber()`.
        guard let whisperKit else {
            throw LocalWhisperError.transcriptionFailed("WhisperKit not initialized")
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            withoutTimestamps: true,
            wordTimestamps: false
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)

        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Pure, stateless helpers — `nonisolated` so plain value types like `SpeechModel` can use them
    // without being dragged onto the main actor.
    nonisolated static func defaultModelID() -> String {
        "small"
    }

    static func currentSelectedModelID() -> String {
        let stored = UserDefaults.standard.string(forKey: modelSelectionKey) ?? ""
        let normalized = normalizedModelID(from: stored)
        return normalized.isEmpty ? defaultModelID() : normalized
    }

    static func modelStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("sniff/whisperkit/models", isDirectory: true)
    }

    static func modelVariant(forModelID modelID: String) -> String {
        switch normalizedModelID(from: modelID) {
        case "turbo":
            return "large-v3_turbo"
        case "large":
            return "large-v3"
        default:
            return normalizedModelID(from: modelID)
        }
    }

    nonisolated static func normalizedModelID(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var model = trimmed
        if model.hasPrefix("ggml-") {
            model.removeFirst("ggml-".count)
        }
        if model.hasSuffix(".bin") {
            model.removeLast(".bin".count)
        }
        if model.hasPrefix("openai_whisper-") {
            model.removeFirst("openai_whisper-".count)
        }
        if let underscoreIndex = model.firstIndex(of: "_"), model[underscoreIndex...].contains("MB") {
            model = String(model[..<underscoreIndex])
        }
        return model
    }

    static func downloadModel(
        named modelID: String,
        progressHandler: (@Sendable (Double, Int, Int) -> Void)? = nil
    ) async throws -> URL {
        let normalizedID = normalizedModelID(from: modelID)
        guard !normalizedID.isEmpty else {
            throw LocalWhisperError.modelDownloadFailed("Invalid model ID")
        }

        let base = modelStorageDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let variant = modelVariant(forModelID: normalizedID)
        let path = try await WhisperKit.download(
            variant: variant,
            downloadBase: base,
            useBackgroundSession: true,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: progressHandler.map { handler in
                // Unpack to plain scalars here: `Progress` is not Sendable, so it must not escape
                // into the caller's (main-actor-hopping) closure.
                { progress in
                    handler(
                        progress.fractionCompleted,
                        Int(progress.completedUnitCount),
                        Int(progress.totalUnitCount)
                    )
                }
            }
        )
        rememberDownloadedModel(id: normalizedID, path: path.path)
        return path
    }

    /// Removes a downloaded model's files and forgets its path, so the row flips back to
    /// "Download" and the disk space is actually reclaimed.
    static func deleteModel(named modelID: String) throws {
        let normalizedID = normalizedModelID(from: modelID)
        var map = downloadedModelPathMap()
        // Falls back to the on-disk location so a model discovered by scanning (rather than by
        // this build having downloaded it) can still be removed.
        let path = map[normalizedID] ?? variantDirectory(forModelID: normalizedID).path
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        map[normalizedID] = nil
        UserDefaults.standard.set(map, forKey: downloadedModelPathMapKey)
    }

    static func listDownloadedModels() -> [String] {
        let map = cleanedDownloadedModelMap()
        return map.keys.sorted()
    }

    static func sizeStringForDownloadedModel(_ modelID: String) -> String? {
        let normalizedID = normalizedModelID(from: modelID)
        let map = cleanedDownloadedModelMap()
        guard let path = map[normalizedID] else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let size = directorySizeInBytes(at: url) else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func estimatedSizeString(for modelName: String) -> String? {
        guard let bytes = estimatedModelSizes[normalizedModelID(from: modelName)] else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func downloadedModelPathMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: downloadedModelPathMapKey) as? [String: String] ?? [:]
    }

    private static func rememberDownloadedModel(id: String, path: String) {
        var map = downloadedModelPathMap()
        map[id] = path
        UserDefaults.standard.set(map, forKey: downloadedModelPathMapKey)
    }

    /// CoreML bundles WhisperKit needs before a variant can actually load. Used to tell a finished
    /// download apart from an interrupted one that left only some of the files behind.
    private static let requiredModelArtifacts = [
        "AudioEncoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
        "TextDecoder.mlmodelc"
    ]

    /// Directory `WhisperKit.download` writes a variant to, given our `downloadBase`.
    private static func variantDirectory(forModelID modelID: String) -> URL {
        modelStorageDirectory()
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(modelVariant(forModelID: modelID))", isDirectory: true)
    }

    private static func isCompleteModelDirectory(_ url: URL) -> Bool {
        requiredModelArtifacts.allSatisfy {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    /// Reconciles the remembered path map with what's actually on disk.
    ///
    /// The map alone isn't trustworthy: it's only written on a successful download in this
    /// container, so models already present would otherwise report as missing and prompt a
    /// multi-gigabyte re-download. Scanning also filters out interrupted downloads that left a
    /// partial set of `.mlmodelc` bundles behind, which would fail at load time instead.
    private static func cleanedDownloadedModelMap() -> [String: String] {
        let existing = downloadedModelPathMap()
        var cleaned: [String: String] = [:]

        for (id, path) in existing {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
               isDir.boolValue,
               isCompleteModelDirectory(url) {
                cleaned[id] = path
            }
        }

        for name in availableModelNames where cleaned[name] == nil {
            let url = variantDirectory(forModelID: name)
            if isCompleteModelDirectory(url) {
                cleaned[name] = url.path
            }
        }

        if cleaned != existing {
            UserDefaults.standard.set(cleaned, forKey: downloadedModelPathMapKey)
        }
        return cleaned
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
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
                continue
            }
            guard values.isRegularFile == true else { continue }
            if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                total += Int64(allocated)
            }
        }
        return total
    }
}

enum LocalWhisperError: Error, LocalizedError {
    case modelDownloadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelDownloadFailed(let message):
            return "Failed to download Whisper model: \(message)"
        case .transcriptionFailed(let message):
            return "Whisper transcription failed: \(message)"
        }
    }
}
