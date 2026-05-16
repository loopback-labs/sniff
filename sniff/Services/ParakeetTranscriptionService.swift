import Foundation
import AVFoundation
import Combine
import FluidAudio

@MainActor
final class ParakeetTranscriptionService: ObservableObject {
    @Published var micTranscribedText: String = ""
    @Published var systemTranscribedText: String = ""
    @Published var isCapturing: Bool = false

    private let audioEngine = AVAudioEngine()
    private lazy var micSampleBridge = MicSampleBridge(label: "com.sniff.parakeet.mic") { [weak self] samples in
        Task { @MainActor [weak self] in
            guard let self, self.capturingInternal else { return }
            self.enqueueVadChunks(from: samples)
        }
    }

    private let micChunkSamples: Int = 4096 // 256ms @ 16kHz
    private let micSampleRate: Double = 16000
    private let micProbabilityThreshold: Float = 0.5
    private let minMicChunkDuration: TimeInterval = 0.8
    private let maxMicChunkDuration: TimeInterval = 12.0

    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var asrModelVersion: AsrModelVersion = .v3

    private var vadContinuation: AsyncStream<[Float]>.Continuation?
    private var vadLoopTask: Task<Void, Never>?

    private var capturingInternal: Bool = false
    private var shouldFinalizeMic: Bool = false

    private var collectingSpeech: Bool = false
    private var currentMicSegmentSamples: [Float] = []
    private var currentMicSegmentMaxProbability: Float = 0

    private var accumulatedMicText: String = ""

    // Buffer mic tap output to micChunkSamples-sized slices for VAD.
    private var vadInputBuffer: [Float] = []

    private var systemSamples: [Float] = []

    // No streaming ASR path; periodically re-transcribe accumulated system audio.
    private var systemRealtimeTranscriptionTask: Task<Void, Never>?
    private var systemRealtimeLastSampleCount: Int = 0
    private let systemRealtimeIntervalSeconds: TimeInterval = 1.0
    private let systemRealtimeMinInitialSamples: Int = 16000 // ~1s @ 16kHz
    private let systemRealtimeMinNewSamples: Int = 8000 // ~0.5s @ 16kHz
    private let systemRealtimeWindowSamples: Int = 240_000 // ~15s @ 16kHz; cap work per realtime pass
    private let systemRealtimeRecentActivitySamples: Int = 16_000 // ~1s tail for RMS / silence
    private let systemRealtimeSilenceRMSThreshold: Float = 0.0025

    private var lastSystemRealtimePublishedNormalized: String = ""

    func reset() {
        accumulatedMicText = ""
        micTranscribedText = ""
        systemTranscribedText = ""
        systemSamples.removeAll()
        vadInputBuffer.removeAll()
        systemRealtimeTranscriptionTask?.cancel()
        systemRealtimeTranscriptionTask = nil
        systemRealtimeLastSampleCount = 0
        lastSystemRealtimePublishedNormalized = ""
    }

    func configure(modelChoice: ParakeetModelChoice) {
        let newVersion = modelChoice.asrModelVersion

        guard self.asrModelVersion != newVersion else { return }
        self.asrModelVersion = newVersion
        self.asrManager = nil
    }

    func startCapture() async throws {
        guard !isCapturing else { return }

        capturingInternal = true
        shouldFinalizeMic = false
        collectingSpeech = false
        currentMicSegmentSamples.removeAll()
        currentMicSegmentMaxProbability = 0
        vadInputBuffer.removeAll()

        do {
            try await ensureManagersLoaded()
            try startMicCapture()
            startVadLoopIfNeeded()
            startSystemRealtimeTranscriptionLoop()
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
        shouldFinalizeMic = finalizeSystem

        stopMicCapture()

        systemRealtimeTranscriptionTask?.cancel()
        await systemRealtimeTranscriptionTask?.value
        systemRealtimeTranscriptionTask = nil

        vadContinuation?.finish()
        vadContinuation = nil

        if !finalizeSystem {
            vadLoopTask?.cancel()
        }
        await vadLoopTask?.value
        vadLoopTask = nil

        isCapturing = false

        if finalizeSystem {
            await transcribeSystemAudio()
        }

        systemSamples.removeAll()
        if !finalizeSystem {
            accumulatedMicText = ""
            lastSystemRealtimePublishedNormalized = ""
            micTranscribedText = ""
            systemTranscribedText = ""
        }
    }

    func appendSystemAudioFloats(_ floats: [Float]) {
        guard capturingInternal else { return }
        systemSamples.append(contentsOf: floats)
    }

    private func ensureManagersLoaded() async throws {
        if asrManager == nil {
            let models = try await AsrModels.downloadAndLoad(version: asrModelVersion)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            asrManager = asr
        }

        if vadManager == nil {
            let vad = try await VadManager(config: VadConfig(defaultThreshold: micProbabilityThreshold))
            vadManager = vad
        }
    }

    private func transcribeParakeetChunk(_ samples: [Float], asrManager: AsrManager) async throws -> ASRResult {
        let layers = await asrManager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: layers)
        return try await asrManager.transcribe(samples, decoderState: &decoderState)
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

    private func startVadLoopIfNeeded() {
        guard vadLoopTask == nil else { return }
        guard let vadManager else { return }
        let stream = AsyncStream<[Float]> { continuation in
            self.vadContinuation = continuation
        }

        vadLoopTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runVadLoop(vadManager: vadManager, chunks: stream)
        }
    }

    private func runVadLoop(vadManager: VadManager, chunks: AsyncStream<[Float]>) async {
        guard let asrManager else { return }

        do {
            let state = await vadManager.makeStreamState()
            var vadState = state

            for await chunk in chunks {
                if Task.isCancelled { break }
                guard !chunk.isEmpty else { continue }

                let vadStreamResult = try await vadManager.processStreamingChunk(
                    chunk,
                    state: vadState,
                    config: .default,
                    returnSeconds: false,
                    timeResolution: 2
                )

                vadState = vadStreamResult.state

                if let event = vadStreamResult.event {
                    switch event.kind {
                    case .speechStart:
                        collectingSpeech = true
                        currentMicSegmentSamples.removeAll(keepingCapacity: true)
                        currentMicSegmentMaxProbability = 0
                    case .speechEnd:
                        break
                    @unknown default:
                        break
                    }
                }

                if collectingSpeech {
                    currentMicSegmentSamples.append(contentsOf: chunk)
                    currentMicSegmentMaxProbability = max(currentMicSegmentMaxProbability, vadStreamResult.probability)
                }

                let currentDurationSeconds = Double(currentMicSegmentSamples.count) / micSampleRate
                let shouldForceEndByDuration = collectingSpeech && currentDurationSeconds >= maxMicChunkDuration

                if shouldForceEndByDuration || vadStreamResult.event?.kind == .speechEnd {
                    try await finalizeMicSegment(asrManager: asrManager)
                }
            }

            if shouldFinalizeMic {
                try await finalizeMicSegment(asrManager: asrManager, allowEmpty: false, force: true)
            }
        } catch {
            print("⚠️ Parakeet VAD loop error: \(error.localizedDescription)")
        }
    }

    private func finalizeMicSegment(
        asrManager: AsrManager,
        allowEmpty: Bool = false,
        force: Bool = false
    ) async throws {
        guard collectingSpeech || force else { return }

        defer {
            collectingSpeech = false
            currentMicSegmentSamples.removeAll(keepingCapacity: true)
            currentMicSegmentMaxProbability = 0
        }

        let samples = currentMicSegmentSamples
        if !allowEmpty && samples.isEmpty { return }

        let durationSeconds = Double(samples.count) / micSampleRate
        guard durationSeconds >= minMicChunkDuration || force else { return }
        guard currentMicSegmentMaxProbability >= micProbabilityThreshold || force else { return }

        let asrResult = try await transcribeParakeetChunk(samples, asrManager: asrManager)
        let segmentText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segmentText.isEmpty else { return }

        accumulatedMicText = TranscriptionTextUtils.appendWithBoundarySmoothing(accumulatedMicText, segmentText)

        micTranscribedText = accumulatedMicText
    }

    private func enqueueVadChunks(from samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard capturingInternal else { return }

        vadInputBuffer.append(contentsOf: samples)

        while vadInputBuffer.count >= micChunkSamples {
            let chunk = Array(vadInputBuffer.prefix(micChunkSamples))
            vadInputBuffer.removeFirst(micChunkSamples)
            vadContinuation?.yield(chunk)
        }
    }

    private func transcribeSystemAudio() async {
        guard let asrManager else { return }
        guard !systemSamples.isEmpty else { return }

        do {
            try await transcribeSystemSamplesAndSetText(systemSamples, asrManager: asrManager)
        } catch {
            print("⚠️ Parakeet system transcription failed: \(error.localizedDescription)")
        }
    }

    private func startSystemRealtimeTranscriptionLoop() {
        guard systemRealtimeTranscriptionTask == nil else { return }
        systemRealtimeLastSampleCount = 0

        systemRealtimeTranscriptionTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runSystemRealtimeTranscriptionLoop()
        }
    }

    private func runSystemRealtimeTranscriptionLoop() async {
        guard let asrManager else { return }
        while !Task.isCancelled {
            guard capturingInternal else { break }

            do {
                try await Task.sleep(nanoseconds: UInt64(systemRealtimeIntervalSeconds * 1_000_000_000))
            } catch {
                break
            }

            guard capturingInternal, !Task.isCancelled else { break }
            let snapshot = systemSamples

            guard !snapshot.isEmpty else { continue }
            let snapshotCount = snapshot.count
            guard snapshotCount >= systemRealtimeMinInitialSamples else { continue }
            guard snapshotCount - systemRealtimeLastSampleCount >= systemRealtimeMinNewSamples || systemRealtimeLastSampleCount == 0 else {
                continue
            }

            // SCStream floats: same decode path as mic; cap tail; skip ASR when recent tail is silent.
            do {
                guard !Task.isCancelled else { return }
                let tail = snapshot.count > systemRealtimeWindowSamples
                    ? Array(snapshot.suffix(systemRealtimeWindowSamples))
                    : snapshot
                guard tail.count >= 16_000 else { continue }

                let recentCount = min(systemRealtimeRecentActivitySamples, tail.count)
                let recentTail = Array(tail.suffix(recentCount))
                let recentRMS = TranscriptionTextUtils.rootMeanSquare(of: recentTail)
                if recentRMS < systemRealtimeSilenceRMSThreshold {
                    systemRealtimeLastSampleCount = snapshotCount
                    continue
                }

                systemRealtimeLastSampleCount = snapshotCount

                let asrResult = try await transcribeParakeetChunk(tail, asrManager: asrManager)
                let raw = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty { continue }
                let text = TranscriptionTextUtils.normalizeSystemText(asrResult.text)
                guard !text.isEmpty, !Task.isCancelled else { continue }
                guard capturingInternal else { continue }
                guard text != lastSystemRealtimePublishedNormalized else { continue }
                lastSystemRealtimePublishedNormalized = text
                systemTranscribedText = text
            } catch {
                if !Task.isCancelled {
                    print("⚠️ Parakeet realtime system transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func transcribeSystemSamplesAndSetText(_ samples: [Float], asrManager: AsrManager) async throws {
        let asrResult = try await transcribeParakeetChunk(samples, asrManager: asrManager)
        let text = TranscriptionTextUtils.normalizeSystemText(asrResult.text)
        guard !text.isEmpty else { return }
        systemTranscribedText = text
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

