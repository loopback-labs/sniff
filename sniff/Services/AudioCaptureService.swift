//
//  AudioCaptureService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import AVFoundation
import Speech
import Combine

@MainActor
class AudioCaptureService: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    @Published var transcribedText: String = ""
    @Published var isCapturing: Bool = false
    @Published var hasPermission: Bool = false
    
    override init() {
        super.init()
        checkPermissions()
    }
    
    func checkPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.hasPermission = status == .authorized
            }
        }
    }
    
    func startCapture() throws {
        guard !isCapturing else { return }
        guard hasPermission else {
            throw AudioCaptureError.permissionDenied
        }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw AudioCaptureError.recognizerUnavailable
        }
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw AudioCaptureError.engineCreationFailed
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw AudioCaptureError.requestCreationFailed
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Speech recognition error: \(error.localizedDescription)")
                // Don't stop on error, keep trying
                return
            }
            
            if let result = result {
                Task { @MainActor in
                    let newText = result.bestTranscription.formattedString
                    // Accumulate text instead of replacing
                    if !newText.isEmpty {
                        if self.transcribedText.isEmpty {
                            self.transcribedText = newText
                        } else {
                            // Only update if we have new content
                            let lastWords = self.transcribedText.components(separatedBy: " ").suffix(5).joined(separator: " ")
                            if !newText.contains(lastWords) || newText.count > self.transcribedText.count {
                                self.transcribedText = newText
                            }
                        }
                        print("📢 Audio transcription: \(newText)")
                    }
                }
            }
            
            // Don't stop on final - keep capturing continuously
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true
    }
    
    func stopCapture() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        isCapturing = false
    }
    
    func captureSystemAudio() throws {
        // Note: System audio capture requires additional setup
        // This is a placeholder - may need BlackHole or similar virtual audio device
        // For now, we'll use the microphone input
        try startCapture()
    }
}

enum AudioCaptureError: Error {
    case permissionDenied
    case recognizerUnavailable
    case engineCreationFailed
    case requestCreationFailed
}

