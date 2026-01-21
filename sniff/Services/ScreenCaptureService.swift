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
import CoreVideo

class ScreenCaptureService: NSObject, ObservableObject {
    private var contentFilter: SCContentFilter?
    private var stream: SCStream?
    private let captureInterval: TimeInterval = 8.0
    private var lastCaptureTime: Date = Date()
    private let captureQueue = DispatchQueue(label: "com.sniff.captureQueue", qos: .userInitiated)
    private let ciContext = CIContext()
    
    @Published var capturedImageData: Data?
    @Published var isCapturing: Bool = false
    
    func startCapture() async throws {
        guard !isCapturing else { return }
        
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = availableContent.displays.first else {
            throw ScreenCaptureError.noDisplay
        }
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        self.contentFilter = filter
        
        let configuration = SCStreamConfiguration()
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.capture.queue", qos: .userInitiated))
        try await stream.startCapture()
        
        self.stream = stream
        self.isCapturing = true
        self.lastCaptureTime = Date()
    }
    
    func stopCapture() async {
        guard isCapturing, let stream = stream else {
            isCapturing = false
            return
        }
        
        // Set capturing to false first to prevent new processing
        await MainActor.run {
            self.isCapturing = false
        }
        
        // Remove stream output before stopping to prevent callbacks during cleanup
        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            print("Failed to remove stream output: \(error)")
        }
        
        do {
            try await stream.stopCapture()
        } catch {
            print("Failed to stop screen capture: \(error)")
        }
        
        self.stream = nil
        self.contentFilter = nil
    }
    
    private func captureImage(from imageBuffer: CVImageBuffer) {
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            print("Failed to create CGImage from buffer")
            return
        }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            print("Failed to convert image to JPEG")
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCapturing else { return }
            self.capturedImageData = jpegData
        }
    }
}

extension ScreenCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        captureQueue.async { [weak self] in
            guard let self = self, self.isCapturing else { return }
            let now = Date()
            let timeSinceLastCapture = now.timeIntervalSince(self.lastCaptureTime)
            guard timeSinceLastCapture >= self.captureInterval else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isCapturing else { return }
                self.lastCaptureTime = Date()
            }
            self.captureImage(from: imageBuffer)
        }
    }
}

enum ScreenCaptureError: Error {
    case noDisplay
    case captureFailed
}

