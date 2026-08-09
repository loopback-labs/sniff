import Foundation
import AVFoundation
import Combine
import FluidAudio

@MainActor
final class ParakeetTranscriptionService: ObservableObject {
    @Published var micUpdate: TranscriptionUpdate = TranscriptionUpdate(text: "", isFinal: true)
    @Published var systemUpdate: TranscriptionUpdate = TranscriptionUpdate(text: "", isFinal: true)
    @Published var isCapturing: Bool = false
    /// Smoothed 0...1 microphone peak, so the UI can show that audio is actually arriving.
    @Published private(set) var micLevel: Float = 0

    private let audioEngine = AVAudioEngine()
    private lazy var micSampleBridge = MicSampleBridge(label: "com.sniff.parakeet.mic") { [weak self] samples in
        Task { @MainActor [weak self] in
            guard let self, self.capturingInternal else { return }
            self.micLevel = AudioLevelMeter.next(level: self.micLevel, samples: samples)
            self.micFeedContinuation?.yield(samples)
        }
    }

    // Parakeet EOU: cache-aware streaming encoder with a built-in, debounced end-of-utterance
    // detector — this replaces the VadManager-based segmentation LocalWhisperService uses, since
    // EOU's own boundary signal maps directly onto `isFinal`. See the streaming-ASR plan for why
    // EOU was chosen over the Nemotron streaming family (no boundary callback, ~2s+ latency).
    private var micStreamer: StreamingEouAsrManager?
    private var systemStreamer: StreamingEouAsrManager?
    private var chunkSize: StreamingChunkSize = .ms320

    private var capturingInternal: Bool = false

    // Each source's chunks are fed to its streamer through a single ordered consumer loop
    // (mirroring VadSegmenter's own AsyncStream pattern) rather than one Task per chunk, so
    // `appendAudio` calls into the stateful streaming encoder can't arrive out of order.
    private var micFeedContinuation: AsyncStream<[Float]>.Continuation?
    private var micFeedTask: Task<Void, Never>?
    private var systemFeedContinuation: AsyncStream<[Float]>.Continuation?
    private var systemFeedTask: Task<Void, Never>?

    /// Awaited rather than fire-and-forget: the previous implementation kicked off streamer resets
    /// in a detached `Task`, so `startCapture()` could begin feeding audio before the reset landed
    /// and the first utterance of a session got wiped mid-flight.
    func reset() async {
        micUpdate = TranscriptionUpdate(text: "", isFinal: true)
        systemUpdate = TranscriptionUpdate(text: "", isFinal: true)
        micLevel = 0
        await micStreamer?.reset()
        await systemStreamer?.reset()
    }

    func configure(modelChoice: ParakeetModelChoice) {
        let newChunkSize = modelChoice.streamingChunkSize
        guard chunkSize != newChunkSize else { return }
        chunkSize = newChunkSize
        // Force re-creation with the new chunk size on next start; a different chunk size means a
        // different model export, not just a config tweak on the existing manager.
        micStreamer = nil
        systemStreamer = nil
    }

    func startCapture() async throws {
        guard !isCapturing else { return }

        capturingInternal = true

        do {
            try await ensureManagersLoaded()
            // Clear decoder/EOU/encoder-cache state before any audio flows. `finish()` (used on
            // stop) empties the token accumulators but leaves `eouDetected` latched true, and a
            // latched streamer never fires another end-of-utterance — so without this a second
            // session would stream partials forever and never commit a line to the transcript.
            await micStreamer?.reset()
            await systemStreamer?.reset()
            startFeedLoop(for: .you)
            startFeedLoop(for: .others)
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

        micFeedContinuation?.finish()
        micFeedContinuation = nil
        systemFeedContinuation?.finish()
        systemFeedContinuation = nil
        await micFeedTask?.value
        await systemFeedTask?.value
        micFeedTask = nil
        systemFeedTask = nil

        if finalizeSystem {
            await finalize(micStreamer, speaker: .you)
            await finalize(systemStreamer, speaker: .others)
        }

        isCapturing = false
    }

    func appendSystemAudioFloats(_ floats: [Float]) {
        guard capturingInternal else { return }
        systemFeedContinuation?.yield(floats)
    }

    private func ensureManagersLoaded() async throws {
        if micStreamer == nil {
            micStreamer = try await makeStreamingManager(speaker: .you)
        }
        if systemStreamer == nil {
            systemStreamer = try await makeStreamingManager(speaker: .others)
        }
    }

    private func makeStreamingManager(speaker: TranscriptSpeaker) async throws -> StreamingEouAsrManager {
        let manager = StreamingEouAsrManager(chunkSize: chunkSize)

        await manager.setPartialCallback { [weak self] text in
            Task { @MainActor [weak self] in
                self?.publish(text: text, speaker: speaker, isFinal: false)
            }
        }
        await manager.setEouCallback { [weak self, weak manager] text in
            // The manager latches EOU until reset, and anything decoded before the reset lands is
            // folded into the finished utterance and then discarded. So the reset goes straight
            // back to the streamer actor instead of hopping via the main actor first (as it used
            // to) — that turned a one-hop window into a main-actor round trip, long enough to swallow
            // the opening words of the next utterance during continuous speech.
            Task { await manager?.reset() }
            Task { @MainActor [weak self] in
                self?.publish(text: text, speaker: speaker, isFinal: true)
            }
        }

        try await manager.loadModels()
        return manager
    }

    private func startFeedLoop(for speaker: TranscriptSpeaker) {
        let stream = AsyncStream<[Float]> { continuation in
            switch speaker {
            case .you: micFeedContinuation = continuation
            case .others: systemFeedContinuation = continuation
            }
        }

        let task = Task(priority: .userInitiated) { [weak self] in
            for await chunk in stream {
                guard let self, !Task.isCancelled else { break }
                let streamer = speaker == .you ? self.micStreamer : self.systemStreamer
                await self.feed(chunk, to: streamer)
            }
        }

        switch speaker {
        case .you: micFeedTask = task
        case .others: systemFeedTask = task
        }
    }

    private func feed(_ samples: [Float], to streamer: StreamingEouAsrManager?) async {
        guard let streamer, let buffer = makePCMBuffer(from: samples) else { return }
        do {
            try await streamer.appendAudio(buffer)
            try await streamer.processBufferedAudio()
        } catch {
            print("⚠️ Parakeet streaming transcription failed: \(error.localizedDescription)")
        }
    }

    private func finalize(_ streamer: StreamingEouAsrManager?, speaker: TranscriptSpeaker) async {
        guard let streamer else { return }
        do {
            let text = try await streamer.finish()
            guard !text.isEmpty else { return }
            publish(text: text, speaker: speaker, isFinal: true)
        } catch {
            print("⚠️ Parakeet final transcription failed (\(speaker)): \(error.localizedDescription)")
        }
    }

    private func publish(text: String, speaker: TranscriptSpeaker, isFinal: Bool) {
        let update = TranscriptionUpdate(text: text, isFinal: isFinal)
        switch speaker {
        case .you: micUpdate = update
        case .others: systemUpdate = update
        }
    }

    private func startMicCapture() throws {
        guard !audioEngine.isRunning else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw ParakeetError.invalidAudioInputFormat
        }

        let bus: AVAudioNodeBus = 0
        inputNode.removeTap(onBus: bus)

        let bridge = micSampleBridge

        inputNode.installTap(onBus: bus, bufferSize: 1024, format: inputFormat) { buffer, _ in
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
}

// MARK: - Model Download Management

extension ParakeetTranscriptionService {
    static func modelStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming", isDirectory: true)
    }

    private static func repo(for choice: ParakeetModelChoice) -> Repo {
        switch choice {
        case .eou160ms: return .parakeetEou160
        case .eou320ms: return .parakeetEou320
        case .eou1280ms: return .parakeetEou1280
        }
    }

    private static func modelDirectory(for choice: ParakeetModelChoice) -> URL {
        modelStorageDirectory().appendingPathComponent(repo(for: choice).folderName, isDirectory: true)
    }

    static func isDownloaded(_ choice: ParakeetModelChoice) -> Bool {
        let dir = modelDirectory(for: choice)
        return ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    static func sizeStringForDownloadedModel(_ choice: ParakeetModelChoice) -> String? {
        guard isDownloaded(choice), let size = directorySizeInBytes(at: modelDirectory(for: choice)) else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func downloadModel(
        _ choice: ParakeetModelChoice,
        progressHandler: (@Sendable (Double, Int, Int) -> Void)? = nil
    ) async throws {
        try await ModelHub.download(
            repo(for: choice),
            to: modelStorageDirectory(),
            progressHandler: progressHandler.map { handler in
                // Flatten FluidAudio's phase enum to (fraction, completedFiles, totalFiles); the
                // listing/compiling phases report no file counts, so they surface as 0 of 0.
                { progress in
                    switch progress.phase {
                    case .downloading(let completed, let total):
                        handler(progress.fractionCompleted, completed, total)
                    case .listing, .compiling:
                        handler(progress.fractionCompleted, 0, 0)
                    }
                }
            }
        )
    }

    /// Removes a downloaded model's directory so the row flips back to "Download" and the disk
    /// space is reclaimed.
    static func deleteModel(_ choice: ParakeetModelChoice) throws {
        let dir = modelDirectory(for: choice)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
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

enum ParakeetError: Error, LocalizedError {
    case invalidAudioInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidAudioInputFormat:
            return "No valid audio input device found. Check microphone connection and permissions."
        }
    }
}
