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

@MainActor
class ScreenCaptureService: NSObject, ObservableObject {
    private var contentFilter: SCContentFilter?
    private var stream: SCStream?
    private let captureInterval: TimeInterval = 2.0
    private var lastCaptureTime: Date = Date()
    
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
        
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.capture.queue"))
        try await stream.startCapture()
        
        self.stream = stream
        self.isCapturing = true
        self.lastCaptureTime = Date()
    }
    
    func stopCapture() async {
        guard let stream = stream else {
            isCapturing = false
            return
        }
        
        do {
            try await stream.stopCapture()
        } catch {
            print("Failed to stop screen capture: \(error)")
        }
        
        self.stream = nil
        self.isCapturing = false
    }
    
    private func extractText(from imageBuffer: CVImageBuffer) {
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, options: [:])
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else { return }
            if let error = error {
                print("OCR error: \(error)")
                return
            }
            
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            let recognizedStrings = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            
            Task { @MainActor in
                self.capturedText = recognizedStrings.joined(separator: " ")
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        do {
            try requestHandler.perform([request])
        } catch {
            print("Failed to perform OCR: \(error)")
        }
    }
}

extension ScreenCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let now = Date()
            let timeSinceLastCapture = now.timeIntervalSince(self.lastCaptureTime)
            
            guard timeSinceLastCapture >= self.captureInterval else { return }
            
            self.lastCaptureTime = now
            self.extractText(from: imageBuffer)
        }
    }
}

enum ScreenCaptureError: Error {
    case noDisplay
    case captureFailed
}

