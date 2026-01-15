//
//  ScreenCaptureService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Combine
import ScreenCaptureKit
import Vision
import AppKit
import CoreVideo

class ScreenCaptureService: NSObject, ObservableObject {
    private var contentFilter: SCContentFilter?
    private var stream: SCStream?
    private let captureInterval: TimeInterval = 8.0
    private var lastCaptureTime: Date = Date()
    private let ocrQueue = DispatchQueue(label: "com.sniff.ocrQueue", qos: .userInitiated)
    
    @Published var capturedText: String = ""
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
    
    private func extractText(from imageBuffer: CVImageBuffer) {
        ocrQueue.async { [weak self] in
            guard let self = self, self.isCapturing else { return }
            let request = VNRecognizeTextRequest { [weak self] request, error in
                guard let self = self, self.isCapturing else { return }
                if let error = error {
                    print("OCR error: \(error)")
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
                let recognizedStrings = observations.compactMap { $0.topCandidates(1).first?.string }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isCapturing else { return }
                    self.capturedText = recognizedStrings.joined(separator: " ")
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, options: [:])
            do {
                try requestHandler.perform([request])
            } catch {
                print("Failed to perform OCR: \(error)")
            }
        }
    }
}

extension ScreenCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Throttle and perform OCR off the main actor
        ocrQueue.async { [weak self] in
            guard let self = self, self.isCapturing else { return }
            let now = Date()
            let timeSinceLastCapture = now.timeIntervalSince(self.lastCaptureTime)
            guard timeSinceLastCapture >= self.captureInterval else { return }
            // Update last capture time on main to keep published state consistent
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isCapturing else { return }
                self.lastCaptureTime = Date()
            }
            self.extractText(from: imageBuffer)
        }
    }
}

enum ScreenCaptureError: Error {
    case noDisplay
    case captureFailed
}

