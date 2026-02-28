//
//  LocalWhisperService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 04/02/26.
//

import Foundation
import Combine
import Speech
import CoreMedia

@MainActor
final class LocalWhisperService: ObservableObject {
    @Published var micTranscribedText: String = ""
    @Published var systemTranscribedText: String = ""
    @Published var isCapturing: Bool = false

    static let availableModelNames: [String] = [
        "tiny", "tiny.en", "base", "base.en", "small", "small.en",
        "medium", "medium.en", "large-v1", "large-v2", "large-v3", "large", "turbo"
    ]

    static let estimatedModelSizes: [String: Int64] = [
        "tiny": 75_000_000, "tiny.en": 75_000_000,
        "base": 142_000_000, "base.en": 142_000_000,
        "small": 466_000_000, "small.en": 466_000_000,
        "medium": 1_500_000_000, "medium.en": 1_500_000_000,
        "large-v1": 2_900_000_000, "large-v2": 2_900_000_000,
        "large-v3": 2_900_000_000, "large": 2_900_000_000,
        "turbo": 1_600_000_000
    ]

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputBuffer = ""
    private var lastEmittedLine = ""
    private static let ansiEscapeRegex: NSRegularExpression = {
        let pattern = "\u{001B}\\[[0-9;?]*[ -/]*[@-~]"
        return try! NSRegularExpression(pattern: pattern)
    }()
    
    private var systemRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var systemRecognitionTask: SFSpeechRecognitionTask?
    private let systemSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    private var binaryPath: String = ""
    private var modelPath: String = ""

    // MARK: - Configuration

    func configure(binaryPath: String, modelPath: String) {
        self.binaryPath = binaryPath
        self.modelPath = modelPath
    }

    // MARK: - Capture Control

    func startCapture() async throws {
        guard !isCapturing else { return }

        let resolvedBinaryPath = (binaryPath as NSString).expandingTildeInPath
        let resolvedModelPath = (modelPath as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: resolvedBinaryPath) else {
            throw LocalWhisperError.binaryNotFound(resolvedBinaryPath)
        }

        if !FileManager.default.fileExists(atPath: resolvedModelPath) {
            try await downloadModel(to: resolvedModelPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBinaryPath)
        process.arguments = ["-m", resolvedModelPath, "-l", "en"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeOutput(data: data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isCapturing = false
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            try startSystemAudioRecognition()
            
            isCapturing = true
        } catch {
            throw LocalWhisperError.launchFailed(error.localizedDescription)
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        
        stopSystemAudioRecognition()
        
        isCapturing = false
    }

    func reset() {
        micTranscribedText = ""
        systemTranscribedText = ""
        outputBuffer = ""
        lastEmittedLine = ""
    }

    func appendSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        systemRecognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
    }

    // MARK: - System Audio Recognition (Apple Speech)

    private func startSystemAudioRecognition() throws {
        guard let systemSpeechRecognizer = systemSpeechRecognizer,
              systemSpeechRecognizer.isAvailable else {
            print("⚠️ System audio recognition unavailable, will only transcribe microphone")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        systemRecognitionRequest = request

        systemRecognitionTask = systemSpeechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error = error {
                print("System audio recognition error: \(error.localizedDescription)")
                return
            }

            guard let result = result else { return }
            let newText = result.bestTranscription.formattedString
            guard !newText.isEmpty else { return }

            Task { @MainActor in
                self?.systemTranscribedText = newText
                print("📢 [Others] \(newText)")
            }
        }
    }

    private func stopSystemAudioRecognition() {
        systemRecognitionTask?.cancel()
        systemRecognitionTask = nil
        systemRecognitionRequest?.endAudio()
        systemRecognitionRequest = nil
    }

    // MARK: - Output Processing (Whisper Stream)

    private func consumeOutput(data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        outputBuffer.append(chunk)

        while let breakIndex = outputBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(outputBuffer[..<breakIndex])
            var nextIndex = outputBuffer.index(after: breakIndex)
            if outputBuffer[breakIndex] == "\r",
               nextIndex < outputBuffer.endIndex,
               outputBuffer[nextIndex] == "\n" {
                nextIndex = outputBuffer.index(after: nextIndex)
            }
            outputBuffer = String(outputBuffer[nextIndex...])
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        let sanitized = sanitizeConsoleLine(line)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !shouldIgnoreLine(trimmed) else { return }

        guard let text = extractText(from: trimmed), !text.isEmpty else { return }
        let normalized = normalize(text)
        guard !normalized.isEmpty, normalized != normalize(lastEmittedLine) else { return }

        lastEmittedLine = text
        if micTranscribedText.isEmpty {
            micTranscribedText = text
        } else {
            micTranscribedText.append(needsSpace(before: text) ? " \(text)" : text)
        }
    }

    private func shouldIgnoreLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("whisper") || lower.hasPrefix("main") || lower.hasPrefix("system_info")
            || lower.contains("whisper_print")
    }

    private func extractText(from line: String) -> String? {
        if let bracketIndex = line.lastIndex(of: "]") {
            return String(line[line.index(after: bracketIndex)...]).trimmingCharacters(in: .whitespaces)
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func needsSpace(before text: String) -> Bool {
        guard let last = micTranscribedText.last, let first = text.first else { return false }
        return !last.isWhitespace && !first.isWhitespace
    }

    private func sanitizeConsoleLine(_ line: String) -> String {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        let withoutAnsi = Self.ansiEscapeRegex.stringByReplacingMatches(
            in: line,
            options: [],
            range: range,
            withTemplate: ""
        )
        let filteredScalars = withoutAnsi.unicodeScalars.filter { scalar in
            let value = scalar.value
            return value == 0x09 || (value >= 0x20 && value != 0x7F)
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    // MARK: - Model Management

    private func downloadModel(to path: String) async throws {
        let modelName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "ggml-", with: "")
        
        guard let downloadURL = Self.downloadURL(for: modelName) else {
            throw LocalWhisperError.modelDownloadFailed("Invalid model name: \(modelName)")
        }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
        
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: path))
    }

    // MARK: - Static Helpers

    static func defaultModelDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("sniff/whisper/models")
    }

    static func defaultModelPath() -> String {
        defaultModelDirectory().appendingPathComponent("ggml-base.en.bin").path
    }

    static func modelURL(for name: String) -> URL {
        defaultModelDirectory().appendingPathComponent("ggml-\(name).bin")
    }

    static func downloadURL(for name: String) -> URL? {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(name).bin")
    }

    static func listDownloadedModels() -> [String] {
        let dir = defaultModelDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
    }

    static func sizeStringForModelFile(_ filename: String) -> String? {
        let url = defaultModelDirectory().appendingPathComponent(filename)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    static func estimatedSizeString(for modelName: String) -> String? {
        guard let bytes = estimatedModelSizes[modelName] else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func detectBinaryPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-stream",
            "/usr/local/bin/whisper-stream",
            "\(NSHomeDirectory())/whisper.cpp/build/bin/whisper-stream",
            "\(NSHomeDirectory())/Desktop/Projects/sniff/whisper.cpp/build/bin/whisper-stream"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func validateBinaryPath(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: expanded)
    }

    static func testBinary(at path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
            throw LocalWhisperError.binaryNotFound(expanded)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: expanded)
        process.arguments = ["--help"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LocalWhisperError.launchFailed("Binary test failed with status \(process.terminationStatus)")
        }
    }
}

enum LocalWhisperError: Error, LocalizedError {
    case binaryNotFound(String)
    case modelDownloadFailed(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "Whisper binary not found at \(path)"
        case .modelDownloadFailed(let message):
            return "Failed to download model: \(message)"
        case .launchFailed(let message):
            return "Failed to launch whisper: \(message)"
        }
    }
}
