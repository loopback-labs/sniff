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
import CoreMedia

@MainActor
class AudioCaptureService: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var micRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micRecognitionTask: SFSpeechRecognitionTask?
    private var systemRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var systemRecognitionTask: SFSpeechRecognitionTask?

    private let micSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let systemSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    @Published var micTranscribedText: String = ""
    @Published var systemTranscribedText: String = ""
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

        guard let micSpeechRecognizer = micSpeechRecognizer,
              micSpeechRecognizer.isAvailable,
              let systemSpeechRecognizer = systemSpeechRecognizer,
              systemSpeechRecognizer.isAvailable else {
            throw AudioCaptureError.recognizerUnavailable
        }

        let micRequest = SFSpeechAudioBufferRecognitionRequest()
        let systemRequest = SFSpeechAudioBufferRecognitionRequest()

        micRequest.shouldReportPartialResults = true
        systemRequest.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            micRequest.addsPunctuation = true
            systemRequest.addsPunctuation = true
        }

        micRecognitionRequest = micRequest
        systemRecognitionRequest = systemRequest

        micRecognitionTask = micSpeechRecognizer.recognitionTask(with: micRequest) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error, speaker: .you)
        }

        systemRecognitionTask = systemSpeechRecognizer.recognitionTask(with: systemRequest) { [weak self] result, error in
            self?.handleRecognitionResult(result, error: error, speaker: .others)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.micRecognitionRequest?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        isCapturing = true
    }

    func stopCapture() {
        guard isCapturing else { return }

        micRecognitionTask?.cancel()
        micRecognitionTask = nil
        systemRecognitionTask?.cancel()
        systemRecognitionTask = nil

        micRecognitionRequest?.endAudio()
        systemRecognitionRequest?.endAudio()
        micRecognitionRequest = nil
        systemRecognitionRequest = nil

        if let audioEngine = audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil

        isCapturing = false
    }

    func reset() {
        micTranscribedText = ""
        systemTranscribedText = ""
    }

    func appendSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        systemRecognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?, speaker: TranscriptSpeaker) {
        if let error = error {
            print("Speech recognition error (\(speaker.displayLabel)): \(error.localizedDescription)")
            return
        }

        guard let result = result else { return }
        let newText = result.bestTranscription.formattedString
        guard !newText.isEmpty else { return }

        Task { @MainActor in
            switch speaker {
            case .you:
                self.micTranscribedText = newText
            case .others:
                self.systemTranscribedText = newText
            }
            print("📢 \(speaker.displayLabel) \(newText)")
        }
    }
}

enum AudioCaptureError: Error {
    case permissionDenied
    case recognizerUnavailable
    case engineCreationFailed
    case requestCreationFailed
}
