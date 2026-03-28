import Foundation
import AVFoundation
import Combine
import CoreMedia
import FluidAudio

final class ParakeetTranscriptionService: ObservableObject {
    @Published var micTranscribedText: String = ""
    @Published var systemTranscribedText: String = ""
    @Published var isCapturing: Bool = false

    private let audioEngine = AVAudioEngine()
    private let audioConverter = AudioConverter()

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

        await MainActor.run { isCapturing = true }

        capturingInternal = true
        shouldFinalizeMic = false
        collectingSpeech = false
        currentMicSegmentSamples.removeAll()
        currentMicSegmentMaxProbability = 0
        vadInputBuffer.removeAll()

        try await ensureManagersLoaded()

        startVadLoopIfNeeded()
        startMicCapture()

        startSystemRealtimeTranscriptionLoop()
    }

    func stopCapture(finalizeSystem: Bool) async {
        guard isCapturing else { return }

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

        await MainActor.run {
            isCapturing = false
        }

        if finalizeSystem {
            await transcribeSystemAudio()
        }

        systemSamples.removeAll()
        if !finalizeSystem {
            accumulatedMicText = ""
            lastSystemRealtimePublishedNormalized = ""
            await MainActor.run { micTranscribedText = "" }
            await MainActor.run { systemTranscribedText = "" }
        }
    }

    func appendSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if !capturingInternal {
            return
        }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let floats = extractFloatSamples(from: sampleBuffer) else { return }
        guard !floats.isEmpty else { return }
        systemSamples.append(contentsOf: floats)
    }

    private func ensureManagersLoaded() async throws {
        if asrManager == nil {
            let models = try await AsrModels.downloadAndLoad(version: asrModelVersion)
            let asr = AsrManager(config: .default)
            try await asr.initialize(models: models)
            asrManager = asr
        }

        if vadManager == nil {
            let vad = try await VadManager(config: VadConfig(defaultThreshold: micProbabilityThreshold))
            vadManager = vad
        }
    }

    private func startMicCapture() {
        guard !audioEngine.isRunning else { return }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let bus: AVAudioNodeBus = 0
        inputNode.removeTap(onBus: bus)

        inputNode.installTap(onBus: bus, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard self.capturingInternal else { return }

            guard let converted = try? self.audioConverter.resampleBuffer(buffer) else { return }
            guard !converted.isEmpty else { return }

            self.enqueueVadChunks(from: converted)
        }

        audioEngine.prepare()
        try? audioEngine.start()
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

        vadLoopTask = Task.detached(priority: .userInitiated) { [weak self] in
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

        let asrResult = try await asrManager.transcribe(samples, source: .microphone)
        let segmentText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segmentText.isEmpty else { return }

        accumulatedMicText = TranscriptionTextUtils.appendWithBoundarySmoothing(accumulatedMicText, segmentText)

        await MainActor.run {
            micTranscribedText = accumulatedMicText
        }
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

        systemRealtimeTranscriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
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

            let snapshot: [Float] = await MainActor.run {
                guard capturingInternal else { return [] }
                return systemSamples
            }

            guard !snapshot.isEmpty else { continue }
            let snapshotCount = snapshot.count
            guard snapshotCount >= systemRealtimeMinInitialSamples else { continue }
            guard snapshotCount - systemRealtimeLastSampleCount >= systemRealtimeMinNewSamples || systemRealtimeLastSampleCount == 0 else {
                continue
            }

            // SCStream floats: transcribe with .microphone; cap tail; skip ASR when recent tail is silent.
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

                let asrResult = try await asrManager.transcribe(tail, source: .microphone)
                let raw = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty { continue }
                let text = TranscriptionTextUtils.normalizeSystemText(asrResult.text)
                guard !text.isEmpty, !Task.isCancelled else { continue }
                await MainActor.run {
                    guard capturingInternal else { return }
                    if text == lastSystemRealtimePublishedNormalized { return }
                    lastSystemRealtimePublishedNormalized = text
                    systemTranscribedText = text
                }
            } catch {
                if !Task.isCancelled {
                    print("⚠️ Parakeet realtime system transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func transcribeSystemSamplesAndSetText(_ samples: [Float], asrManager: AsrManager) async throws {
        let asrResult = try await asrManager.transcribe(samples, source: .microphone)
        let text = TranscriptionTextUtils.normalizeSystemText(asrResult.text)
        guard !text.isEmpty else { return }
        await MainActor.run {
            systemTranscribedText = text
        }
    }

    private func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        SystemAudioSampleBufferPCM.extractMonoFloatSamples(from: sampleBuffer)
    }
}

