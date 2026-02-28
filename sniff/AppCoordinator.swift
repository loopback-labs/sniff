//
//  AppCoordinator.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI
import AppKit
import Combine
import CoreGraphics
import CoreMedia
import HotKey

@MainActor
class AppCoordinator: ObservableObject {
    let screenCaptureService = ScreenCaptureService()
    let audioCaptureService = AudioCaptureService()
    let localWhisperService = LocalWhisperService()
    let audioDeviceService = AudioDeviceService()
    let questionDetectionService = QuestionDetectionService()
    let qaManager = QAManager()
    let transcriptBuffer = TranscriptBuffer()
    let keychainService = KeychainService()
    
    private var llmService: LLMService?
    private var qaOverlayWindow: NSWindow?
    private var transcriptOverlayWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private var toggleHotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var screenCaptureSubscription: AnyCancellable?
    private let audioQuestionPipeline: AudioQuestionPipeline
    private let appleMicDeltaProcessor = TranscriptionDeltaProcessor()
    private let appleSystemDeltaProcessor = TranscriptionDeltaProcessor()
    private let whisperMicDeltaProcessor = TranscriptionDeltaProcessor()
    private let whisperSystemDeltaProcessor = TranscriptionDeltaProcessor()
    
    @Published var isRunning = false
    @Published var automaticMode = false {
        didSet {
            guard isRunning else { return }
            // Screen capture always runs for manual trigger
            // Only toggle the auto-processing subscription
            if automaticMode {
                setupScreenCaptureSubscription()
            } else {
                screenCaptureSubscription?.cancel()
                screenCaptureSubscription = nil
            }
        }
    }
    @Published var selectedProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedLLMProvider")
            rebuildLLMService()
        }
    }
    @Published var selectedSpeechEngine: SpeechEngine {
        didSet {
            UserDefaults.standard.set(selectedSpeechEngine.rawValue, forKey: "selectedSpeechEngine")
            if isRunning {
                Task { await restartSpeechCapture() }
            }
        }
    }
    @Published var showOverlay: Bool {
        didSet {
            UserDefaults.standard.set(showOverlay, forKey: "showOverlay")
            updateOverlayVisibility()
        }
    }
    
    init() {
        let savedProvider = UserDefaults.standard.string(forKey: "selectedLLMProvider") ?? LLMProvider.perplexity.rawValue
        selectedProvider = LLMProvider(rawValue: savedProvider) ?? .perplexity
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        let savedSpeechEngine = UserDefaults.standard.string(forKey: "selectedSpeechEngine") ?? SpeechEngine.apple.rawValue
        selectedSpeechEngine = SpeechEngine(rawValue: savedSpeechEngine) ?? .apple
        
        audioQuestionPipeline = AudioQuestionPipeline(questionDetectionService: questionDetectionService)
        
        rebuildLLMService()
        applySavedAudioInputDevice()
        
        toggleHotKey = HotKey(key: .w, modifiers: [.command, .shift])
        toggleHotKey?.keyDownHandler = { [weak self] in
            self?.toggle()
        }
    }
    
    private func applySavedAudioInputDevice() {
        guard let savedUID = UserDefaults.standard.string(forKey: "selectedAudioInputDeviceUID") else { return }
        do {
            try audioDeviceService.setDefaultInputDevice(byUID: savedUID)
        } catch {
            print("Failed to restore saved audio input device: \(error)")
        }
    }
    
    func rebuildLLMService() {
        guard let apiKey = keychainService.getAPIKey(for: selectedProvider) else {
            llmService = nil
            return
        }
        switch selectedProvider {
        case .openai:
            llmService = OpenAIService(apiKey: apiKey)
        case .claude:
            llmService = ClaudeService(apiKey: apiKey)
        case .gemini:
            llmService = GeminiService(apiKey: apiKey)
        case .perplexity:
            llmService = PerplexityService(apiKey: apiKey)
        }
    }

    private func currentSourcePublishers() -> [(speaker: TranscriptSpeaker, publisher: AnyPublisher<String, Never>)] {
        switch selectedSpeechEngine {
        case .apple:
            return [
                (.you, audioCaptureService.$micTranscribedText.eraseToAnyPublisher()),
                (.others, audioCaptureService.$systemTranscribedText.eraseToAnyPublisher())
            ]
        case .whisper:
            return [
                (.you, localWhisperService.$micTranscribedText.eraseToAnyPublisher()),
                (.others, localWhisperService.$systemTranscribedText.eraseToAnyPublisher())
            ]
        }
    }

    private func currentTranscribedText() -> String {
        let text = transcriptBuffer.recentTextForDetection()
        return stripSpeakerLabels(from: text)
    }

    private func startSpeechCapture(using engine: SpeechEngine) async throws {
        switch engine {
        case .apple:
            try audioCaptureService.startCapture()
        case .whisper:
            configureWhisperService()
            try await localWhisperService.startCapture()
        }
    }

    private func stopSpeechCapture() {
        audioCaptureService.stopCapture()
        localWhisperService.stopCapture()
    }

    private func restartSpeechCapture() async {
        guard isRunning else { return }

        let engineForSystemAudio = selectedSpeechEngine
        stopSpeechCapture()
        resetDeltaProcessors()
        audioCaptureService.reset()
        localWhisperService.reset()
        cancellables.removeAll()
        setupSubscriptions()
        do {
            await screenCaptureService.stopCapture()
            do {
                try await screenCaptureService.startCapture(
                    enableSystemAudio: true,
                    audioSampleHandler: makeSystemAudioHandler(for: engineForSystemAudio)
                )
            } catch {
                print("⚠️ System audio capture unavailable after restart; continuing with microphone-only transcription: \(error)")
            }
            try await startSpeechCapture(using: engineForSystemAudio)
        } catch {
            print("Failed to restart speech capture: \(error)")
        }
    }

    private func configureWhisperService() {
        // Get stored paths or auto-detect
        let storedBinaryPath = UserDefaults.standard.string(forKey: "whisperBinaryPath") ?? ""
        let storedModelPath = UserDefaults.standard.string(forKey: "whisperModelPath") ?? ""
        
        // Use stored path if valid, otherwise auto-detect
        let binaryPath: String
        if !storedBinaryPath.isEmpty && LocalWhisperService.validateBinaryPath(storedBinaryPath) {
            binaryPath = storedBinaryPath
        } else if let detected = LocalWhisperService.detectBinaryPath() {
            binaryPath = detected
        } else {
            binaryPath = "/opt/homebrew/bin/whisper-stream"
        }
        
        // Use stored model path if exists, otherwise use default
        let modelPath: String
        if !storedModelPath.isEmpty && FileManager.default.fileExists(atPath: storedModelPath) {
            modelPath = storedModelPath
        } else {
            modelPath = LocalWhisperService.defaultModelPath()
        }
        
        localWhisperService.configure(binaryPath: binaryPath, modelPath: modelPath)
    }

    // Legacy bookmark handling removed - using temporary exception entitlements instead
    private func resolveBookmarkURL(forKey key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                let newData = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(newData, forKey: key)
            }
            return url
        } catch {
            print("Failed to resolve bookmark \(key): \(error)")
            return nil
        }
    }
    
    private func setupSubscriptions() {
        let sourcePublishers = currentSourcePublishers()
        let mergedPublisher = Publishers.MergeMany(sourcePublishers.map { $0.publisher })
            .receive(on: RunLoop.main)
            .share()

        sourcePublishers.forEach { source in
            source.publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] text in
                    guard let self = self else { return }
                    let delta = self.deltaProcessor(for: source.speaker).consume(text)
                    guard !delta.isEmpty else { return }
                    self.transcriptBuffer.append(deltaText: delta, speaker: source.speaker)
                }
                .store(in: &cancellables)
        }

        mergedPublisher
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.transcriptBuffer.refreshDisplay()
            }
            .store(in: &cancellables)

        mergedPublisher
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let recentText = self.stripSpeakerLabels(from: self.transcriptBuffer.recentTextForDetection())
                guard !recentText.isEmpty else { return }
                
                let result = self.audioQuestionPipeline.process(recentText: recentText)
                
                // Always update the latest question (even if nil to clear old highlights)
                if let latestQuestion = result.latestQuestion {
                    print("🔍 Detected audio question: \(latestQuestion.prefix(50))...")
                }
                self.transcriptBuffer.updateLatestQuestion(result.latestQuestion)
                
                // Process new questions in auto mode
                if self.automaticMode {
                    for question in result.questions {
                        self.processQuestion(question, source: .audio, screenContext: nil)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func deltaProcessor(for speaker: TranscriptSpeaker) -> TranscriptionDeltaProcessor {
        switch (selectedSpeechEngine, speaker) {
        case (.apple, .you):
            return appleMicDeltaProcessor
        case (.apple, .others):
            return appleSystemDeltaProcessor
        case (.whisper, .you):
            return whisperMicDeltaProcessor
        case (.whisper, .others):
            return whisperSystemDeltaProcessor
        }
    }

    private func resetDeltaProcessors() {
        appleMicDeltaProcessor.reset()
        appleSystemDeltaProcessor.reset()
        whisperMicDeltaProcessor.reset()
        whisperSystemDeltaProcessor.reset()
    }

    private func stripSpeakerLabels(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\[(You|Others)\]\s*"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSystemAudioHandler(for engine: SpeechEngine) -> (CMSampleBuffer) -> Void {
        { [weak self] sampleBuffer in
            guard let self = self else { return }
            Task { @MainActor in
                switch engine {
                case .apple:
                    self.audioCaptureService.appendSystemAudioSampleBuffer(sampleBuffer)
                case .whisper:
                    self.localWhisperService.appendSystemAudioSampleBuffer(sampleBuffer)
                }
            }
        }
    }
    
    private func setupScreenCaptureSubscription() {
        screenCaptureSubscription?.cancel()
        screenCaptureSubscription = screenCaptureService.$capturedImageData
            .compactMap { $0 }
            .sink { [weak self] imageData in
                self?.processScreenImage(imageData)
            }
    }
    
    func toggle() {
        Task {
            if isRunning {
                await stop()
            } else {
                await start()
            }
        }
    }
    
    func start() async {
        guard !isRunning else { return }
        
        // Check API key
        guard llmService != nil else {
            showSettingsWindow()
            return
        }
        
        transcriptBuffer.clear()
        resetDeltaProcessors()
        audioCaptureService.reset()
        localWhisperService.reset()
        let saveURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("sniff-transcripts")
        transcriptBuffer.startSession(saveDirectoryURL: saveURL)
        audioQuestionPipeline.reset()
        setupSubscriptions()
        await requestPermissions()
        
        do {
            do {
                try await screenCaptureService.startCapture(
                    enableSystemAudio: true,
                    audioSampleHandler: makeSystemAudioHandler(for: selectedSpeechEngine)
                )
            } catch {
                print("⚠️ Screen/system audio capture unavailable; continuing with microphone-only transcription: \(error)")
            }

            if automaticMode {
                setupScreenCaptureSubscription()
            }

            try await startSpeechCapture(using: selectedSpeechEngine)
            createQAOverlayWindow()
            createTranscriptOverlayWindow()
            setupKeyboardShortcuts()
            isRunning = true
        } catch {
            print("Failed to start services: \(error)")
            cancellables.removeAll()
            screenCaptureSubscription?.cancel()
            screenCaptureSubscription = nil
        }
    }
    
    func stop() async {
        guard isRunning else { return }
        
        cancellables.removeAll()
        screenCaptureSubscription?.cancel()
        screenCaptureSubscription = nil
        await screenCaptureService.stopCapture()
        stopSpeechCapture()
        transcriptBuffer.stopSession()
        
        // Clean up hotkeys
        hotKeys.removeAll()
        
        for window in [qaOverlayWindow, transcriptOverlayWindow] {
            window?.ignoresMouseEvents = true
            window?.contentView = nil
            window?.orderOut(nil)
        }
        qaOverlayWindow = nil
        transcriptOverlayWindow = nil
        
        isRunning = false
    }
    
    func requestPermissions() async {
        let granted = await withCheckedContinuation { continuation in
            continuation.resume(returning: CGRequestScreenCaptureAccess())
        }
        if !granted {
            print("Screen recording permission denied")
        }
    }
    
    private func createQAOverlayWindow() {
        let config = WindowConfiguration.qaOverlay
        qaOverlayWindow = createWindow(config: config) {
            QAOverlayContent(qaManager: qaManager)
                .environmentObject(self)
        }
    }

    private func createTranscriptOverlayWindow() {
        let config = WindowConfiguration.transcript
        transcriptOverlayWindow = createWindow(config: config) {
            TranscriptOverlayContentView(transcriptBuffer: transcriptBuffer)
        }
    }
    
    private func createWindow<Content: View>(config: WindowConfiguration, @ViewBuilder content: () -> Content) -> NSWindow {
        let window = OverlayWindow(config: config)
        window.setScreenshotInclusion(showOverlay)
        window.contentView = NSHostingView(rootView: content().environment(\.overlayWindow, window))
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        print("🪟 \(config.name) overlay window created at: \(window.frame)")
        return window
    }
    
    private func setupKeyboardShortcuts() {
        // Clear any existing hotkeys
        hotKeys.removeAll()
        
        // Cmd+Shift+Q: Screen question trigger (global)
        let screenQuestionHotKey = HotKey(key: .q, modifiers: [.command, .shift])
        screenQuestionHotKey.keyDownHandler = { [weak self] in
            self?.triggerScreenQuestion()
        }
        hotKeys.append(screenQuestionHotKey)
        
        // Cmd+Shift+A: Audio question trigger (global)
        let audioQuestionHotKey = HotKey(key: .a, modifiers: [.command, .shift])
        audioQuestionHotKey.keyDownHandler = { [weak self] in
            self?.triggerAudioQuestion()
        }
        hotKeys.append(audioQuestionHotKey)
        
        // Cmd+Shift+M: Toggle Automatic Mode (global)
        let toggleAutomaticModeHotKey = HotKey(key: .m, modifiers: [.command, .shift])
        toggleAutomaticModeHotKey.keyDownHandler = { [weak self] in
            self?.automaticMode.toggle()
        }
        hotKeys.append(toggleAutomaticModeHotKey)
        
        // Option+Left arrow: Previous (only when overlay is key)
        let optionLeftKey = HotKey(key: .leftArrow, modifiers: [.option])
        optionLeftKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToPrevious()
        }
        hotKeys.append(optionLeftKey)
        
        // Option+Right arrow: Next (only when overlay is key)
        let optionRightKey = HotKey(key: .rightArrow, modifiers: [.option])
        optionRightKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToNext()
        }
        hotKeys.append(optionRightKey)
        
        // Option+Up: First (only when overlay is key)
        let optionUpKey = HotKey(key: .upArrow, modifiers: [.option])
        optionUpKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToFirst()
        }
        hotKeys.append(optionUpKey)
        
        // Option+Down: Last (only when overlay is key)
        let optionDownKey = HotKey(key: .downArrow, modifiers: [.option])
        optionDownKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToLast()
        }
        hotKeys.append(optionDownKey)

        // Cmd+Shift+R: Quits the app
        let quitHotKey = HotKey(key: .r, modifiers: [.command, .shift])
        quitHotKey.keyDownHandler = { [weak self] in
            guard let self = self else { return }
            Task {
                await self.stop()
                await MainActor.run {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        hotKeys.append(quitHotKey)
    }
    
    func triggerScreenQuestion() {
        print("🖥️ Screen question triggered")
        Task {
            guard let imageData = await screenCaptureService.captureCurrentFrame() else {
                print("⚠️ No screenshot available")
                return
            }
            print("   Screenshot available: \(imageData.count) bytes")
            processScreenImage(imageData)
        }
    }
    
    func triggerAudioQuestion() {
        print("🎙️ Audio question triggered")
        let audioText = currentTranscribedText()
        print("   Audio text: \(audioText.isEmpty ? "empty" : String(audioText.prefix(50)))")
        guard let question = resolveAudioQuestion(from: audioText) else { return }
        processQuestion(question, source: .manual, screenContext: nil)
    }

    private func resolveAudioQuestion(from audioText: String) -> String? {
        // First check if we have a latest detected question
        if let latestQuestion = transcriptBuffer.latestQuestion {
            print("   Using latest detected question: \(latestQuestion.prefix(50))...")
            return latestQuestion
        }

        guard !audioText.isEmpty else {
            print("⚠️ No audio text available to process as question")
            return nil
        }

        // Try to detect question from audio
        if let question = questionDetectionService.firstQuestion(in: audioText) {
            print("   Detected question: \(question.prefix(50))...")
            return question
        }

        print("   No question detected, using raw audio text as fallback")
        return audioText
    }
    
    private func processQuestion(_ question: String, source: QuestionSource, screenContext: String?) {
        if isDuplicateRecent(question) {
            print("⚠️ Duplicate question detected, skipping: \(question)")
            return
        }
        
        print("❓ Question detected (\(source)): \(question)")
        let item = qaManager.addQuestion(question, source: source, screenContext: screenContext)
        Task { await getAnswer(for: item) }
    }
    
    private func processScreenImage(_ imageData: Data) {
        let prompt = "Solve the problem or answer the question shown in this image."
        print("📺 Processing screen image with prompt")
        let item = qaManager.addQuestion(prompt, source: .screen, screenContext: nil)
        Task { await getAnswer(for: item, imageData: imageData) }
    }
    
    private func isDuplicateRecent(_ question: String) -> Bool {
        let recentQuestions = qaManager.items.filter {
            abs($0.timestamp.timeIntervalSinceNow) < 30
        }
        return recentQuestions.contains { $0.question.lowercased() == question.lowercased() }
    }
    
    private func getAnswer(for item: QAItem, imageData: Data? = nil) async {
        guard isRunning, let llmService = llmService else {
            print("❌ No LLM service available or app stopped")
            qaManager.updateAnswer(for: item.id, answer: "Error: Missing API key or app stopped")
            return
        }
        
        print("🔍 Requesting answer\(imageData != nil ? " with image" : ""): \(item.question.prefix(50))...")
        
        do {
            var buffer = ""
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: "")
            
            let onChunk: (String) -> Void = { chunk in
                Task { @MainActor in
                    guard !chunk.isEmpty, self.isRunning else { return }
                    buffer += chunk
                    self.qaManager.updateAnswer(for: item.id, answer: buffer)
                }
            }
            
            let answer: String
            if let imageData = imageData {
                answer = try await llmService.streamAnswerWithImage(prompt: item.question, imageData: imageData, onChunk: onChunk)
            } else {
                answer = try await llmService.streamAnswer(item.question, screenContext: item.screenContext, onChunk: onChunk)
            }

            print("✅ Answer received: \(answer.prefix(100))...")
            guard isRunning else { return }
            let itemId = item.id
            Task { @MainActor in
                self.qaManager.updateAnswer(for: itemId, answer: answer)
            }
        } catch {
            print("❌ Failed to get answer: \(error)")
            if let llmError = error as? LLMError {
                print("   Error details: \(llmError)")
            }
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: "Error: \(error.localizedDescription)")
        }
    }
    
    func showSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // If settings window exists and is visible, just bring it to front
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Settings"
        let settingsView = SettingsView()
            .environmentObject(self)
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        window.isReleasedWhenClosed = false
        settingsWindow = window
    }
    
    func updateAPIKey(_ key: String, for provider: LLMProvider) {
        do {
            try keychainService.saveAPIKey(key, for: provider)
            if provider == selectedProvider {
                rebuildLLMService()
            }
        } catch {
            print("Failed to update API key: \(error)")
        }
    }
    
    private func updateOverlayVisibility() {
        guard isRunning else { return }
        (qaOverlayWindow as? OverlayWindow)?.setScreenshotInclusion(showOverlay)
        (transcriptOverlayWindow as? OverlayWindow)?.setScreenshotInclusion(showOverlay)
        
        if qaOverlayWindow == nil {
            createQAOverlayWindow()
        }
        if transcriptOverlayWindow == nil {
            createTranscriptOverlayWindow()
        }
    }
}
