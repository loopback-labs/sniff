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

    static let modelSelectionKey = "whisperModelId"

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
    private let audioConverter = AudioConverter()

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

    private var micRealtimeLastSampleCount = 0
    private var systemRealtimeLastSampleCount = 0

    private let realtimeIntervalSeconds: TimeInterval = 1.0
    private let realtimeMinInitialSamples: Int = 16_000
    private let realtimeMinNewSamples: Int = 8_000
    private let realtimeWindowSamples: Int = 240_000
    private let realtimeRecentActivitySamples: Int = 16_000
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
        micRealtimeLastSampleCount = 0
        systemRealtimeLastSampleCount = 0
        transcriptionInFlight = false

        startMicCapture()
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
        micRealtimeLastSampleCount = 0
        systemRealtimeLastSampleCount = 0
        transcriptionInFlight = false
        isCapturing = false
    }

    func appendSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard capturingInternal else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let floats = SystemAudioSampleBufferPCM.extractMonoFloatSamples(from: sampleBuffer) else { return }
        guard !floats.isEmpty else { return }
        systemSamples.append(contentsOf: floats)
    }

    func reset() {
        micTranscribedText = ""
        systemTranscribedText = ""
        accumulatedMicText = ""
        lastMicPublishedNormalized = ""
        lastSystemPublishedNormalized = ""
        micSamples.removeAll()
        systemSamples.removeAll()
        micRealtimeLastSampleCount = 0
        systemRealtimeLastSampleCount = 0
    }

    private func ensureWhisperKitReady() async throws {
        let modelID = configuredModelID.isEmpty ? Self.defaultModelID() : configuredModelID
        let variant = Self.modelVariant(forModelID: modelID)

        if whisperKit != nil, loadedModelVariant == variant {
            return
        }

        let modelFolder = try await Self.downloadModel(named: modelID)
        var config = WhisperKitConfig(
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

    private func startMicCapture() {
        guard !audioEngine.isRunning else { return }
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard self.capturingInternal else { return }
            guard let converted = try? self.audioConverter.resampleBuffer(buffer) else { return }
            guard !converted.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.micSamples.append(contentsOf: converted)
            }
        }

        audioEngine.prepare()
        try? audioEngine.start()
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
            let snapshot = micSamples
            let snapshotCount = snapshot.count
            guard snapshotCount >= realtimeMinInitialSamples else { continue }
            guard snapshotCount - micRealtimeLastSampleCount >= realtimeMinNewSamples || micRealtimeLastSampleCount == 0 else { continue }

            let tail = snapshotCount > realtimeWindowSamples
                ? Array(snapshot.suffix(realtimeWindowSamples))
                : snapshot
            guard !tail.isEmpty else { continue }

            let recentCount = min(realtimeRecentActivitySamples, tail.count)
            let recentTail = Array(tail.suffix(recentCount))
            guard Self.rootMeanSquare(of: recentTail) >= realtimeSilenceRMSThreshold else {
                micRealtimeLastSampleCount = snapshotCount
                continue
            }

            micRealtimeLastSampleCount = snapshotCount
            do {
                let text = try await transcribe(samples: tail)
                guard !text.isEmpty else { continue }
                let normalized = Self.normalize(text)
                guard normalized != lastMicPublishedNormalized else { continue }
                lastMicPublishedNormalized = normalized
                accumulatedMicText = appendWithBoundarySmoothing(accumulatedMicText, text)
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
            let snapshot = systemSamples
            let snapshotCount = snapshot.count
            guard snapshotCount >= realtimeMinInitialSamples else { continue }
            guard snapshotCount - systemRealtimeLastSampleCount >= realtimeMinNewSamples || systemRealtimeLastSampleCount == 0 else { continue }

            let tail = snapshotCount > realtimeWindowSamples
                ? Array(snapshot.suffix(realtimeWindowSamples))
                : snapshot
            guard !tail.isEmpty else { continue }

            let recentCount = min(realtimeRecentActivitySamples, tail.count)
            let recentTail = Array(tail.suffix(recentCount))
            guard Self.rootMeanSquare(of: recentTail) >= realtimeSilenceRMSThreshold else {
                systemRealtimeLastSampleCount = snapshotCount
                continue
            }

            systemRealtimeLastSampleCount = snapshotCount
            do {
                let raw = try await transcribe(samples: tail)
                guard !raw.isEmpty else { continue }
                let text = normalizeSystemText(raw)
                guard !text.isEmpty, text != lastSystemPublishedNormalized else { continue }
                lastSystemPublishedNormalized = text
                systemTranscribedText = text
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
            accumulatedMicText = appendWithBoundarySmoothing(accumulatedMicText, text)
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
            let text = normalizeSystemText(raw)
            guard !text.isEmpty else { return }
            systemTranscribedText = text
        } catch {
            print("⚠️ [WhisperKit] Final system transcription failed: \(error.localizedDescription)")
        }
    }

    private func transcribe(samples: [Float]) async throws -> String {
        guard !transcriptionInFlight else { return "" }
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
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private func normalizeSystemText(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = text.last, !".!?".contains(last) {
            text.append(".")
        }
        return text
    }

    private func appendWithBoundarySmoothing(_ existing: String, _ addition: String) -> String {
        guard !addition.isEmpty else { return existing }
        guard !existing.isEmpty else { return addition }

        let maxSuffixChars = 48
        let suffix = String(existing.suffix(maxSuffixChars))
        if addition.hasPrefix(suffix) {
            let trimmed = String(addition.dropFirst(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return existing }
            return existing + " " + trimmed
        }

        if existing.last?.isWhitespace == true {
            return existing + addition
        }
        return existing + " " + addition
    }

    private static func rootMeanSquare(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for x in samples {
            sum += x * x
        }
        return sqrt(sum / Float(samples.count))
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
