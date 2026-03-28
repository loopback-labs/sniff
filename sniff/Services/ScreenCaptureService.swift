//
//  ScreenCaptureService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Combine
import ScreenCaptureKit
import AppKit
import CoreMedia

class ScreenCaptureService: NSObject, ObservableObject {
    private var contentFilter: SCContentFilter?
    private var stream: SCStream?
    // .screen output must be registered or SCK logs dropped frames; samples unused (screenshots via SCScreenshotManager).
    private let screenOutputQueue = DispatchQueue(label: "com.sniff.screen.output", qos: .utility)
    private let audioOutputQueue = DispatchQueue(label: "com.sniff.audio.output", qos: .userInitiated)
    nonisolated(unsafe) private var audioSampleHandler: ((CMSampleBuffer) -> Void)?
    nonisolated(unsafe) private var isSystemAudioEnabled = false

    @Published var isCapturing: Bool = false

    func startCapture(
        enableSystemAudio: Bool,
        audioSampleHandler: ((CMSampleBuffer) -> Void)? = nil
    ) async throws {
        guard !isCapturing else { return }

        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = availableContent.displays.first else {
            throw ScreenCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.contentFilter = filter
        self.audioSampleHandler = audioSampleHandler
        self.isSystemAudioEnabled = enableSystemAudio

        let configuration = SCStreamConfiguration()
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = enableSystemAudio
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        if enableSystemAudio {
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenOutputQueue)
        if enableSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioOutputQueue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.isCapturing = true
    }

    func stopCapture() async {
        guard isCapturing, let stream = stream else {
            isCapturing = false
            return
        }

        await MainActor.run {
            self.isCapturing = false
        }

        if isSystemAudioEnabled {
            do {
                try stream.removeStreamOutput(self, type: .audio)
            } catch {
                print("Failed to remove audio stream output: \(error)")
            }
        }

        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            print("Failed to remove screen stream output: \(error)")
        }

        do {
            try await stream.stopCapture()
        } catch {
            print("Failed to stop screen capture: \(error)")
        }

        self.stream = nil
        self.contentFilter = nil
        self.audioSampleHandler = nil
        self.isSystemAudioEnabled = false
    }

    private func jpegData(from cgImage: CGImage) -> Data? {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            print("Failed to convert image to JPEG")
            return nil
        }
        return jpegData
    }

    func captureCurrentFrame() async -> Data? {
        guard isCapturing, let contentFilter = contentFilter else { return nil }

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: config
            )
            return jpegData(from: cgImage)
        } catch {
            print("Failed to capture screenshot: \(error)")
            return nil
        }
    }
}

extension ScreenCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            break
        case .audio:
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            audioSampleHandler?(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }
}

enum ScreenCaptureError: Error {
    case noDisplay
}
