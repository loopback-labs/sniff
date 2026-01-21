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
import HotKey

@MainActor
class AppCoordinator: ObservableObject {
    let screenCaptureService = ScreenCaptureService()
    let audioCaptureService = AudioCaptureService()
    let audioDeviceService = AudioDeviceService()
    let questionDetectionService = QuestionDetectionService()
    let technicalQuestionClassifier = TechnicalQuestionClassifier()
    let qaManager = QAManager()
    let transcriptBuffer = TranscriptBuffer()
    let keychainService = KeychainService()
    
    private var llmService: LLMService?
    private var qaOverlayWindow: NSWindow?
    private var transcriptOverlayWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private var toggleHotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var screenCaptureSubscription: AnyCancellable?
    private let questionDetectionDeltaProcessor = TranscriptionDeltaProcessor()
    private let audioQuestionPipeline: AudioQuestionPipeline
    private let transcriptUpdateService: TranscriptUpdateService
    
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
        
        // Initialize services
        audioQuestionPipeline = AudioQuestionPipeline(questionDetectionService: questionDetectionService)
        transcriptUpdateService = TranscriptUpdateService(transcriptBuffer: transcriptBuffer)
        
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
    
    private func setupSubscriptions() {
        // Update transcript display
        audioCaptureService.$transcribedText
            .sink { [weak self] text in
                self?.transcriptUpdateService.updateDisplay(with: text)
            }
            .store(in: &cancellables)
        
        // Continuous audio question detection + auto processing (consolidated)
        // Uses trailing window to handle pauses in speech
        audioCaptureService.$transcribedText
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self = self, !text.isEmpty else { return }
                
                // Process transcribed text through pipeline
                let result = self.audioQuestionPipeline.process(transcribedText: text)
                
                // Always store latest question for manual trigger
                if let latestQuestion = result.latestQuestion {
                    print("🔍 Detected audio question: \(latestQuestion.prefix(50))...")
                    self.transcriptUpdateService.updateLatestQuestion(latestQuestion)
                }
                
                // If auto mode is on, process all detected questions
                if self.automaticMode {
                    for question in result.questions {
                        self.processQuestion(question, source: .audio, screenContext: nil)
                    }
                }
            }
            .store(in: &cancellables)
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
        
        questionDetectionDeltaProcessor.reset()
        transcriptBuffer.clear()
        setupSubscriptions()
        await requestPermissions()
        
        do {
            // Always start screen capture (needed for manual trigger)
            try await screenCaptureService.startCapture()
            
            // Only setup auto-processing subscription if automaticMode is enabled
            if automaticMode {
                setupScreenCaptureSubscription()
            }
            
            try audioCaptureService.startCapture()
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
        audioCaptureService.stopCapture()
        
        // Clean up hotkeys
        hotKeys.removeAll()
        
        qaOverlayWindow?.close()
        qaOverlayWindow = nil
        transcriptOverlayWindow?.close()
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
            TranscriptOverlayContent(transcriptBuffer: transcriptBuffer)
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
        
        // Left arrow: Previous (only when overlay is key)
        let leftArrowHotKey = HotKey(key: .leftArrow, modifiers: [])
        leftArrowHotKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToPrevious()
        }
        hotKeys.append(leftArrowHotKey)
        
        // Right arrow: Next (only when overlay is key)
        let rightArrowHotKey = HotKey(key: .rightArrow, modifiers: [])
        rightArrowHotKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToNext()
        }
        hotKeys.append(rightArrowHotKey)
        
        // Cmd+Up: First (only when overlay is key)
        let cmdUpHotKey = HotKey(key: .upArrow, modifiers: [.command])
        cmdUpHotKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToFirst()
        }
        hotKeys.append(cmdUpHotKey)
        
        // Cmd+Down: Last (only when overlay is key)
        let cmdDownHotKey = HotKey(key: .downArrow, modifiers: [.command])
        cmdDownHotKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true else { return }
            self.qaManager.goToLast()
        }
        hotKeys.append(cmdDownHotKey)
    }
    
    func triggerScreenQuestion() {
        print("🖥️ Screen question triggered")
        
        guard let imageData = screenCaptureService.capturedImageData else {
            print("⚠️ No screenshot available")
            return
        }
        
        print("   Screenshot available: \(imageData.count) bytes")
        processScreenImage(imageData)
    }
    
    func triggerAudioQuestion() {
        print("🎙️ Audio question triggered")
        let audioText = audioCaptureService.transcribedText
        print("   Audio text: \(audioText.isEmpty ? "empty" : String(audioText.prefix(50)))")
        
        // First check if we have a latest detected question
        if let latestQuestion = transcriptBuffer.latestQuestion {
            print("   Using latest detected question: \(latestQuestion.prefix(50))...")
            processQuestion(latestQuestion, source: .manual, screenContext: nil)
            return
        }
        
        guard !audioText.isEmpty else {
            print("⚠️ No audio text available to process as question")
            return
        }
        
        // Try to detect question from audio
        let audioQuestions = questionDetectionService.detectFromAudio(audioText)
        if let question = audioQuestions.first {
            print("   Detected question: \(question.prefix(50))...")
            processQuestion(question, source: .manual, screenContext: nil)
        } else {
            print("   No question detected, using raw audio text as fallback")
            processQuestion(audioText, source: .manual, screenContext: nil)
        }
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
        let prompt = "Solve the problem or answer the question shown in this image. Be concise and accurate."
        print("📺 Processing screen image with prompt")
        let item = qaManager.addQuestion(prompt, source: .screen, screenContext: nil)
        Task { await getAnswerWithImage(for: item, imageData: imageData) }
    }
    
    private func getAnswerWithImage(for item: QAItem, imageData: Data) async {
        guard isRunning, let llmService = llmService else {
            print("❌ No LLM service available or app stopped")
            qaManager.updateAnswer(for: item.id, answer: "Error: Missing API key or app stopped")
            return
        }
        
        print("🔍 Requesting answer with image...")
        
        do {
            var buffer = ""
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: "")
            
            let answer = try await llmService.streamAnswerWithImage(
                prompt: item.question,
                imageData: imageData
            ) { chunk in
                Task { @MainActor in
                    guard !chunk.isEmpty, self.isRunning else { return }
                    buffer += chunk
                    self.qaManager.updateAnswer(for: item.id, answer: buffer)
                }
            }
            
            print("✅ Answer received: \(answer.prefix(100))...")
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: answer)
        } catch {
            print("❌ Failed to get answer: \(error)")
            if let llmError = error as? LLMError {
                print("   Error details: \(llmError)")
            }
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: "Error: \(error.localizedDescription)")
        }
    }

    private func isDuplicateRecent(_ question: String) -> Bool {
        let recentQuestions = qaManager.items.filter {
            abs($0.timestamp.timeIntervalSinceNow) < 30
        }
        return recentQuestions.contains { $0.question.lowercased() == question.lowercased() }
    }
    
    private func getAnswer(for item: QAItem) async {
        guard isRunning, let llmService = llmService else {
            print("❌ No LLM service available or app stopped")
            qaManager.updateAnswer(for: item.id, answer: "Error: Missing API key or app stopped")
            return
        }
        
        print("🔍 Requesting answer for: \(item.question)")
        
        do {
            var buffer = ""
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: "")

            let answer = try await llmService.streamAnswer(
                item.question,
                screenContext: item.screenContext
            ) { chunk in
                Task { @MainActor in
                    guard !chunk.isEmpty, self.isRunning else { return }
                    buffer += chunk
                    self.qaManager.updateAnswer(for: item.id, answer: buffer)
                }
            }

            print("✅ Answer received: \(answer.prefix(100))...")
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: answer)
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
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
        
        window.isReleasedWhenClosed = false
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

