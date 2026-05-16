import AVFoundation
import FluidAudio

nonisolated final class MicSampleBridge: @unchecked Sendable {
    private let queue: DispatchQueue
    private let converter = AudioConverter()
    private let onSamples: @Sendable ([Float]) -> Void

    init(label: String, onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.onSamples = onSamples
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let snapshot = Self.snapshotMonoFloatSamples(from: buffer) else { return }
        queue.async { [converter, onSamples, snapshot] in
            guard let converted = try? converter.resample(snapshot.samples, from: snapshot.sampleRate) else { return }
            guard !converted.isEmpty else { return }
            onSamples(converted)
        }
    }

    private static func snapshotMonoFloatSamples(from buffer: AVAudioPCMBuffer) -> MicSampleSnapshot? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }

        if let channelData = buffer.floatChannelData {
            if channelCount == 1 {
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
                return MicSampleSnapshot(samples: samples, sampleRate: buffer.format.sampleRate)
            }

            var mono = [Float](repeating: 0, count: frameCount)
            let weight = Float(1.0 / Double(channelCount))
            for channel in 0..<channelCount {
                for frame in 0..<frameCount {
                    mono[frame] += channelData[channel][frame] * weight
                }
            }
            return MicSampleSnapshot(samples: mono, sampleRate: buffer.format.sampleRate)
        }

        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.isInterleaved,
              let source = buffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        let interleaved = source.assumingMemoryBound(to: Float.self)
        var mono = [Float](repeating: 0, count: frameCount)
        let weight = Float(1.0 / Double(channelCount))
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += interleaved[frame * channelCount + channel]
            }
            mono[frame] = sum * weight
        }
        return MicSampleSnapshot(samples: mono, sampleRate: buffer.format.sampleRate)
    }
}

nonisolated struct MicSampleSnapshot: Sendable {
    let samples: [Float]
    let sampleRate: Double
}
