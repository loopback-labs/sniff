import Foundation
import AVFoundation
import Combine
import CoreMedia
import FluidAudio
import WhisperKit

@MainActor
final class LocalWhisperService: ObservableObject {
    @Published var micTranscribedText: String = ""
    @Published var systemTranscribedText: String = ""
    @Published var isCapturing: Bool = false

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
            self.micSamples.append(contentsOf: samples)
            if self.micSamples.count > self.realtimeWindowSamples {
                let excess = self.micSamples.count - self.realtimeWindowSamples
                self.micSamples.removeFirst(excess)
                self.micUnprocessedStart = max(0, self.micUnprocessedStart - excess)
            }
        }
    }

    private var configuredModelID: String = LocalWhisperService.defaultModelID()
    private var loadedModelVariant: String?
    private var whisperKit: WhisperKit?

    private var capturingInternal = false
    private var transcriptionInFlight = false

    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []
    private var accumulatedMicText = ""
    private var lastMicPublishedNormalized = ""
    private var lastSystemPublishedNormalized = ""

    private var micRealtimeTask: Task<Void, Never>?
    private var systemRealtimeTask: Task<Void, Never>?

    private let contextOverlapSamples: Int = 32_000
    private var micUnprocessedStart: Int = 0
    private var systemUnprocessedStart: Int = 0
    private var accumulatedSystemText = ""

    private let realtimeIntervalSeconds: TimeInterval = 1.0
    private let realtimeMinInitialSamples: Int = 16_000
    private let realtimeMinNewSamples: Int = 8_000
    private let realtimeWindowSamples: Int = 240_000
    private let realtimeSilenceRMSThreshold: Float = 0.0025

    func configure(modelID: String) {
        let normalized = Self.normalizedModelID(from: modelID)
        configuredModelID = normalized.isEmpty ? Self.defaultModelID() : normalized
        UserDefaults.standard.set(configuredModelID, forKey: Self.modelSelectionKey)
    }

    func startCapture() async throws {
        guard !isCapturing else { return }

        try await ensureWhisperKitReady()

        capturingInternal = true
        micSamples.removeAll(keepingCapacity: true)
        systemSamples.removeAll(keepingCapacity: true)
        micUnprocessedStart = 0
        systemUnprocessedStart = 0
        transcriptionInFlight = false

        try startMicCapture()
        startRealtimeLoops()
        isCapturing = true
    }

    func stopCapture() {
        Task { await stopAll(finalizeSystem: false) }
    }

    func stopAll(finalizeSystem: Bool) async {
        guard capturingInternal || isCapturing else { return }

        capturingInternal = false
        stopMicCapture()

        micRealtimeTask?.cancel()
        systemRealtimeTask?.cancel()
        await micRealtimeTask?.value
        await systemRealtimeTask?.value
        micRealtimeTask = nil
        systemRealtimeTask = nil

        if finalizeSystem {
            await finalizeMicTranscriptionIfNeeded()
            await finalizeSystemTranscriptionIfNeeded()
        }

        micSamples.removeAll(keepingCapacity: true)
        systemSamples.removeAll(keepingCapacity: true)
        micUnprocessedStart = 0
        systemUnprocessedStart = 0
        transcriptionInFlight = false
        isCapturing = false
    }

    func appendSystemAudioFloats(_ floats: [Float]) {
        guard capturingInternal else { return }
        systemSamples.append(contentsOf: floats)
        if systemSamples.count > realtimeWindowSamples {
            let excess = systemSamples.count - realtimeWindowSamples
            systemSamples.removeFirst(excess)
            systemUnprocessedStart = max(0, systemUnprocessedStart - excess)
        }
    }

    func reset() {
        micTranscribedText = ""
        systemTranscribedText = ""
        accumulatedMicText = ""
        accumulatedSystemText = ""
        lastMicPublishedNormalized = ""
        lastSystemPublishedNormalized = ""
        micSamples.removeAll()
        systemSamples.removeAll()
        micUnprocessedStart = 0
        systemUnprocessedStart = 0
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

    private func startRealtimeLoops() {
        if micRealtimeTask == nil {
            micRealtimeTask = Task { [weak self] in
                await self?.runMicRealtimeLoop()
            }
        }
        if systemRealtimeTask == nil {
            systemRealtimeTask = Task { [weak self] in
                await self?.runSystemRealtimeLoop()
            }
        }
    }

    private func runMicRealtimeLoop() async {
        while !Task.isCancelled {
            guard capturingInternal else { break }
            do {
                try await Task.sleep(nanoseconds: UInt64(realtimeIntervalSeconds * 1_000_000_000))
            } catch {
                break
            }

            guard capturingInternal else { break }
            // Skip the tick while the shared transcriber is busy, leaving all pointers/buffers
            // untouched so the audio stays queued for the next tick instead of being dropped.
            guard !transcriptionInFlight else { continue }
            let totalSamples = micSamples.count
            guard totalSamples >= realtimeMinInitialSamples else { continue }

            let unprocessedCount = totalSamples - micUnprocessedStart
            guard unprocessedCount >= realtimeMinNewSamples else { continue }

            // Gate on the whole unprocessed range: a quiet last second must not discard
            // speech accumulated earlier in the backlog.
            let unprocessed = Array(micSamples[micUnprocessedStart...])
            guard TranscriptionTextUtils.rootMeanSquare(of: unprocessed) >= realtimeSilenceRMSThreshold else {
                micUnprocessedStart = totalSamples
                continue
            }

            let windowStart = max(0, micUnprocessedStart - contextOverlapSamples)
            let skipBeforeSeconds = windowStart > 0 ? Double(contextOverlapSamples) / 16000.0 : 0
            let tail = Array(micSamples[windowStart...])

            micUnprocessedStart = totalSamples

            if windowStart > 0 {
                micSamples.removeFirst(windowStart)
                micUnprocessedStart -= windowStart
            }

            do {
                let text = try await transcribe(samples: tail, skipBeforeSeconds: skipBeforeSeconds)
                guard !text.isEmpty else { continue }
                let normalized = Self.normalize(text)
                guard normalized != lastMicPublishedNormalized else { continue }
                lastMicPublishedNormalized = normalized
                accumulatedMicText = TranscriptionTextUtils.appendWithBoundarySmoothing(accumulatedMicText, text)
                micTranscribedText = accumulatedMicText
            } catch {
                if !Task.isCancelled {
                    print("⚠️ [WhisperKit] Realtime mic transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runSystemRealtimeLoop() async {
        while !Task.isCancelled {
            guard capturingInternal else { break }
            do {
                try await Task.sleep(nanoseconds: UInt64(realtimeIntervalSeconds * 1_000_000_000))
            } catch {
                break
            }

            guard capturingInternal else { break }
            // Skip the tick while the shared transcriber is busy, leaving all pointers/buffers
            // untouched so the audio stays queued for the next tick instead of being dropped.
            guard !transcriptionInFlight else { continue }
            let totalSamples = systemSamples.count
            guard totalSamples >= realtimeMinInitialSamples else { continue }

            let unprocessedCount = totalSamples - systemUnprocessedStart
            guard unprocessedCount >= realtimeMinNewSamples else { continue }

            // Gate on the whole unprocessed range: a quiet last second must not discard
            // speech accumulated earlier in the backlog.
            let unprocessed = Array(systemSamples[systemUnprocessedStart...])
            guard TranscriptionTextUtils.rootMeanSquare(of: unprocessed) >= realtimeSilenceRMSThreshold else {
                systemUnprocessedStart = totalSamples
                continue
            }

            let windowStart = max(0, systemUnprocessedStart - contextOverlapSamples)
            let skipBeforeSeconds = windowStart > 0 ? Double(contextOverlapSamples) / 16000.0 : 0
            let tail = Array(systemSamples[windowStart...])

            systemUnprocessedStart = totalSamples

            if windowStart > 0 {
                systemSamples.removeFirst(windowStart)
                systemUnprocessedStart -= windowStart
            }

            do {
                let raw = try await transcribe(samples: tail, skipBeforeSeconds: skipBeforeSeconds)
                guard !raw.isEmpty else { continue }
                let text = TranscriptionTextUtils.normalizeSystemText(raw)
                guard !text.isEmpty else { continue }
                guard text != lastSystemPublishedNormalized else { continue }
                lastSystemPublishedNormalized = text
                accumulatedSystemText = TranscriptionTextUtils.appendWithBoundarySmoothing(accumulatedSystemText, text)
                systemTranscribedText = accumulatedSystemText
            } catch {
                if !Task.isCancelled {
                    print("⚠️ [WhisperKit] Realtime system transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finalizeMicTranscriptionIfNeeded() async {
        guard !micSamples.isEmpty else { return }
        do {
            let text = try await transcribe(samples: micSamples)
            guard !text.isEmpty else { return }
            let normalized = Self.normalize(text)
            guard normalized != lastMicPublishedNormalized else { return }
            accumulatedMicText = TranscriptionTextUtils.appendWithBoundarySmoothing(accumulatedMicText, text)
            lastMicPublishedNormalized = normalized
            micTranscribedText = accumulatedMicText
        } catch {
            print("⚠️ [WhisperKit] Final mic transcription failed: \(error.localizedDescription)")
        }
    }

    private func finalizeSystemTranscriptionIfNeeded() async {
        guard !systemSamples.isEmpty else { return }
        do {
            let raw = try await transcribe(samples: systemSamples)
            let text = TranscriptionTextUtils.normalizeSystemText(raw)
            guard !text.isEmpty else { return }
            accumulatedSystemText = TranscriptionTextUtils.appendWithBoundarySmoothing(accumulatedSystemText, text)
            systemTranscribedText = accumulatedSystemText
        } catch {
            print("⚠️ [WhisperKit] Final system transcription failed: \(error.localizedDescription)")
        }
    }

    private func transcribe(samples: [Float], skipBeforeSeconds: Double = 0) async throws -> String {
        guard let whisperKit else {
            throw LocalWhisperError.transcriptionFailed("WhisperKit not initialized")
        }

        transcriptionInFlight = true
        defer { transcriptionInFlight = false }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            withoutTimestamps: false,
            wordTimestamps: false
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)

        if skipBeforeSeconds > 0 {
            return results
                .flatMap { $0.segments }
                .filter { Double($0.start) >= skipBeforeSeconds }
                .map { $0.text }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func defaultModelID() -> String {
        "small"
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

    static func normalizedModelID(from value: String) -> String {
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

    static func downloadModel(named modelID: String) async throws -> URL {
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
            from: "argmaxinc/whisperkit-coreml"
        )
        rememberDownloadedModel(id: normalizedID, path: path.path)
        return path
    }

    static func listDownloadedModels() -> [String] {
        let map = cleanedDownloadedModelMap()
        return map.keys.sorted()
    }

    static func isModelDownloaded(_ modelID: String) -> Bool {
        cleanedDownloadedModelMap().keys.contains(normalizedModelID(from: modelID))
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

    private static func cleanedDownloadedModelMap() -> [String: String] {
        let existing = downloadedModelPathMap()
        var cleaned: [String: String] = [:]
        for (id, path) in existing {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                cleaned[id] = path
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
