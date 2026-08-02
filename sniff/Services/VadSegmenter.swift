//
//  VadSegmenter.swift
//  sniff
//

import AVFoundation
import Foundation
import FluidAudio

/// Segments a live 16kHz mono float audio stream into speech utterances using FluidAudio's
/// Silero-based `VadManager`, rather than an amplitude-threshold VAD — see the streaming-ASR
/// plan notes on why WhisperKit's own `EnergyVAD` isn't a fit for call audio.
///
/// Feed audio via `enqueue(_:)`. `onPartial` fires as a segment accumulates (for revisable
/// partial transcription); `onSegment` fires once on `speechEnd` or the max-duration cutoff,
/// and is awaited so ASR work naturally serializes against VAD processing the same way the
/// original hand-rolled Parakeet mic loop did.
@MainActor
final class VadSegmenter {
    struct Configuration {
        var chunkSamples: Int = 4096 // 256ms @ 16kHz
        var sampleRate: Double = 16000
        var probabilityThreshold: Float = 0.5
        var minSegmentDuration: TimeInterval = 0.8
        var maxSegmentDuration: TimeInterval = 12.0
    }

    /// Invoked with the in-progress segment's samples every time new audio is appended while
    /// collecting speech. The array grows across calls until the segment finalizes.
    var onPartial: (([Float]) -> Void)?
    /// Invoked once with the finalized segment's samples, on `speechEnd` or max-duration cutoff.
    /// Errors from ASR work triggered here are the caller's responsibility to catch.
    var onSegment: (([Float]) async -> Void)?

    private let configuration: Configuration
    private var vadManager: VadManager?

    private var continuation: AsyncStream<[Float]>.Continuation?
    private var loopTask: Task<Void, Never>?

    private var collectingSpeech = false
    private var currentSegmentSamples: [Float] = []
    private var currentSegmentMaxProbability: Float = 0

    private var inputBuffer: [Float] = []
    private var shouldFinalizeOnStop = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Loads the VAD model (if needed) and starts the segmentation loop. Safe to call again
    /// after `stop(finalizingRemainder:)`.
    func start() async throws {
        guard loopTask == nil else { return }
        if vadManager == nil {
            vadManager = try await VadManager(config: VadConfig(defaultThreshold: configuration.probabilityThreshold))
        }
        guard let vadManager else { return }

        collectingSpeech = false
        currentSegmentSamples.removeAll()
        currentSegmentMaxProbability = 0
        inputBuffer.removeAll()
        shouldFinalizeOnStop = false

        let stream = AsyncStream<[Float]> { continuation in
            self.continuation = continuation
        }
        loopTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runLoop(vadManager: vadManager, chunks: stream)
        }
    }

    /// Stops the segmenter. If `finalizingRemainder` is true and a segment is in progress, it is
    /// force-flushed to `onSegment` (awaited) before this returns.
    func stop(finalizingRemainder: Bool) async {
        shouldFinalizeOnStop = finalizingRemainder
        continuation?.finish()
        continuation = nil
        if !finalizingRemainder {
            loopTask?.cancel()
        }
        await loopTask?.value
        loopTask = nil
    }

    /// Clears in-progress segment state without touching the loaded VAD model or the running loop.
    func reset() {
        collectingSpeech = false
        currentSegmentSamples.removeAll()
        currentSegmentMaxProbability = 0
        inputBuffer.removeAll()
    }

    /// Feed live audio samples (16kHz mono float). Re-chunked internally to `chunkSamples`
    /// before being handed to the VAD stream.
    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        inputBuffer.append(contentsOf: samples)
        while inputBuffer.count >= configuration.chunkSamples {
            let chunk = Array(inputBuffer.prefix(configuration.chunkSamples))
            inputBuffer.removeFirst(configuration.chunkSamples)
            continuation?.yield(chunk)
        }
    }

    private func runLoop(vadManager: VadManager, chunks: AsyncStream<[Float]>) async {
        var vadState = await vadManager.makeStreamState()

        do {
            for await chunk in chunks {
                if Task.isCancelled { break }
                guard !chunk.isEmpty else { continue }

                let result = try await vadManager.processStreamingChunk(
                    chunk,
                    state: vadState,
                    config: .default,
                    returnSeconds: false,
                    timeResolution: 2
                )
                vadState = result.state

                if let event = result.event {
                    switch event.kind {
                    case .speechStart:
                        collectingSpeech = true
                        currentSegmentSamples.removeAll(keepingCapacity: true)
                        currentSegmentMaxProbability = 0
                    case .speechEnd:
                        break
                    @unknown default:
                        break
                    }
                }

                if collectingSpeech {
                    currentSegmentSamples.append(contentsOf: chunk)
                    currentSegmentMaxProbability = max(currentSegmentMaxProbability, result.probability)
                    onPartial?(currentSegmentSamples)
                }

                let currentDurationSeconds = Double(currentSegmentSamples.count) / configuration.sampleRate
                let shouldForceEndByDuration = collectingSpeech && currentDurationSeconds >= configuration.maxSegmentDuration

                if shouldForceEndByDuration || result.event?.kind == .speechEnd {
                    await finalizeSegment()
                }
            }

            if shouldFinalizeOnStop {
                await finalizeSegment(allowEmpty: false, force: true)
            }
        } catch {
            print("⚠️ VadSegmenter loop error: \(error.localizedDescription)")
        }
    }

    private func finalizeSegment(allowEmpty: Bool = false, force: Bool = false) async {
        guard collectingSpeech || force else { return }

        defer {
            collectingSpeech = false
            currentSegmentSamples.removeAll(keepingCapacity: true)
            currentSegmentMaxProbability = 0
        }

        let samples = currentSegmentSamples
        if !allowEmpty && samples.isEmpty { return }

        let durationSeconds = Double(samples.count) / configuration.sampleRate
        guard durationSeconds >= configuration.minSegmentDuration || force else { return }
        guard currentSegmentMaxProbability >= configuration.probabilityThreshold || force else { return }

        await onSegment?(samples)
    }
}

/// Wraps 16kHz mono float samples into an `AVAudioPCMBuffer` — the format FluidAudio's streaming
/// ASR managers (e.g. `StreamingEouAsrManager.appendAudio(_:)`) expect as input. Returns `nil` for
/// empty input or if the format/buffer can't be allocated.
func makePCMBuffer(from samples: [Float], sampleRate: Double = 16000) -> AVAudioPCMBuffer? {
    guard !samples.isEmpty,
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    else { return nil }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
        guard let baseAddress = source.baseAddress else { return }
        buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
    }
    return buffer
}
