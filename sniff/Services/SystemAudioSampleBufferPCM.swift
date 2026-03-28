//
//  SystemAudioSampleBufferPCM.swift
//  sniff
//
//  Shared ScreenCaptureKit → mono float PCM extraction for transcription backends.
//

import CoreMedia
import CoreAudio

enum SystemAudioSampleBufferPCM {
    private static var didLogUnsupportedFormat = false

    static func extractMonoFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return nil }

        let asbd = asbdPtr.pointee
        let numberOfChannels = max(1, Int(asbd.mChannelsPerFrame))

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: nil,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return nil }

        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return [] }

        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let totalScalarCount = Int(numFrames) * numberOfChannels

        if isFloat && bitsPerChannel == 32 {
            return dataPointer.withMemoryRebound(to: Float.self, capacity: totalScalarCount) { floatPointer in
                if numberOfChannels == 1 {
                    return Array(UnsafeBufferPointer(start: floatPointer, count: totalScalarCount))
                }

                var out = [Float]()
                out.reserveCapacity(Int(numFrames))
                for frameIndex in 0..<Int(numFrames) {
                    var sum: Float = 0
                    for ch in 0..<numberOfChannels {
                        let idx = isNonInterleaved
                            ? (ch * Int(numFrames) + frameIndex)
                            : (frameIndex * numberOfChannels + ch)
                        sum += floatPointer[idx]
                    }
                    out.append(sum / Float(numberOfChannels))
                }
                return out
            }
        } else if isFloat && bitsPerChannel == 64 {
            return dataPointer.withMemoryRebound(to: Double.self, capacity: totalScalarCount) { doublePointer in
                if numberOfChannels == 1 {
                    return (0..<totalScalarCount).map { i in Float(doublePointer[i]) }
                }

                var out = [Float]()
                out.reserveCapacity(Int(numFrames))
                for frameIndex in 0..<Int(numFrames) {
                    var sum: Double = 0
                    for ch in 0..<numberOfChannels {
                        let idx = isNonInterleaved
                            ? (ch * Int(numFrames) + frameIndex)
                            : (frameIndex * numberOfChannels + ch)
                        sum += doublePointer[idx]
                    }
                    out.append(Float(sum / Double(numberOfChannels)))
                }
                return out
            }
        } else if !isFloat && bitsPerChannel == 16 {
            return dataPointer.withMemoryRebound(to: Int16.self, capacity: totalScalarCount) { intPointer in
                if numberOfChannels == 1 {
                    return (0..<totalScalarCount).map { i in Float(intPointer[i]) / 32768.0 }
                }

                var out = [Float]()
                out.reserveCapacity(Int(numFrames))
                for frameIndex in 0..<Int(numFrames) {
                    var sum: Float = 0
                    for ch in 0..<numberOfChannels {
                        let idx = isNonInterleaved
                            ? (ch * Int(numFrames) + frameIndex)
                            : (frameIndex * numberOfChannels + ch)
                        sum += Float(intPointer[idx]) / 32768.0
                    }
                    out.append(sum / Float(numberOfChannels))
                }
                return out
            }
        } else if !isFloat && bitsPerChannel == 32 {
            return dataPointer.withMemoryRebound(to: Int32.self, capacity: totalScalarCount) { intPointer in
                if numberOfChannels == 1 {
                    return (0..<totalScalarCount).map { i in Float(intPointer[i]) / 2147483648.0 }
                }

                var out = [Float]()
                out.reserveCapacity(Int(numFrames))
                for frameIndex in 0..<Int(numFrames) {
                    var sum: Float = 0
                    for ch in 0..<numberOfChannels {
                        let idx = isNonInterleaved
                            ? (ch * Int(numFrames) + frameIndex)
                            : (frameIndex * numberOfChannels + ch)
                        sum += Float(intPointer[idx]) / 2147483648.0
                    }
                    out.append(sum / Float(numberOfChannels))
                }
                return out
            }
        } else {
            if !didLogUnsupportedFormat {
                didLogUnsupportedFormat = true
                print("⚠️ System audio sample format not handled: isFloat=\(isFloat) bitsPerChannel=\(bitsPerChannel) channels=\(numberOfChannels)")
            }
            return nil
        }
    }
}
