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
    private var cancellables = Set<AnyCancellable>()
    private let transcriptionDeltaProcessor = TranscriptionDeltaProcessor()
    
    @Published var isRunning = false
    @Published var automaticMode = true
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
        rebuildLLMService()
        applySavedAudioInputDevice()
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
        audioCaptureService.$transcribedText
            .sink { [weak self] text in
                self?.transcriptBuffer.update(with: text)
            }
            .store(in: &cancellables)

        screenCaptureService.$capturedText
            .debounce(for: .seconds(8), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self = self, self.automaticMode, !text.isEmpty else { return }
                print("📺 Screen text captured: \(text.prefix(100))...")
                self.processDetectedQuestions(from: text, source: .screen, screenContext: text)
            }
            .store(in: &cancellables)
        
        audioCaptureService.$transcribedText
            .debounce(for: .seconds(4), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self = self, self.automaticMode, !text.isEmpty else { return }
                let delta = self.transcriptionDeltaProcessor.consume(text)
                guard !delta.isEmpty else { return }
                print("🎤 Audio text (delta): \(delta)")
                self.processDetectedQuestions(from: delta, source: .audio, screenContext: nil)
            }
            .store(in: &cancellables)
    }
    
    func start() async {
        guard !isRunning else { return }
        
        // Check API key
        guard llmService != nil else {
            showSettingsWindow()
            return
        }
        
        transcriptionDeltaProcessor.reset()
        transcriptBuffer.clear()
        setupSubscriptions()
        await requestPermissions()
        
        do {
            try await screenCaptureService.startCapture()
            try audioCaptureService.startCapture()
            createQAOverlayWindow()
            createTranscriptOverlayWindow()
            setupKeyboardShortcuts()
            isRunning = true
        } catch {
            print("Failed to start services: \(error)")
            cancellables.removeAll()
        }
    }
    
    func stop() async {
        guard isRunning else { return }
        
        cancellables.removeAll()
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
        let size = NSSize(width: 600, height: 400)
        qaOverlayWindow = createOverlayWindow(
            size: size,
            position: .topRight,
            contentView: OverlayContentView(qaManager: qaManager).environmentObject(self),
            name: "Q&A"
        )
    }

    private func createTranscriptOverlayWindow() {
        let size = NSSize(width: 480, height: 160)
        transcriptOverlayWindow = createOverlayWindow(
            size: size,
            position: .topLeft,
            contentView: TranscriptOverlayView(transcriptBuffer: transcriptBuffer),
            name: "Transcript"
        )
    }
    
    private enum WindowPosition {
        case topLeft, topRight
    }
    
    private func createOverlayWindow(size: NSSize, position: WindowPosition, contentView: some View, name: String) -> NSWindow {
        let screenRect = (NSScreen.main ?? NSScreen.screens.first!).visibleFrame
        let padding: CGFloat = 20
        let x = position == .topLeft
            ? screenRect.minX + padding
            : screenRect.maxX - size.width - padding

        let rect = NSRect(
            x: x,
            y: screenRect.maxY - size.height - padding,
            width: size.width,
            height: size.height
        )
        
        let window = OverlayWindow(contentRect: rect)
        window.setFrame(rect, display: true)
        window.minSize = size
        window.maxSize = screenRect.size
        window.setScreenshotInclusion(showOverlay)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        print("🪟 \(name) overlay window created at: \(rect)")
        return window
    }
    
    private func setupKeyboardShortcuts() {
        // Clear any existing hotkeys
        hotKeys.removeAll()
        
        // Cmd+Shift+Q: Manual question trigger (global)
        let manualQuestionHotKey = HotKey(key: .q, modifiers: [.command, .shift])
        manualQuestionHotKey.keyDownHandler = { [weak self] in
            self?.triggerManualQuestion()
        }
        hotKeys.append(manualQuestionHotKey)
        
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
    
    func triggerManualQuestion() {
        print("🔘 Manual question triggered")
        let screenText = screenCaptureService.capturedText
        let audioText = audioCaptureService.transcribedText
        
        print("   Screen text: \(screenText.isEmpty ? "empty" : String(screenText.prefix(50)))")
        print("   Audio text: \(audioText.isEmpty ? "empty" : String(audioText.prefix(50)))")
        
        // Try to detect question from screen, then audio
        let screenQuestions = questionDetectionService.detectFromScreen(screenText)
        if let question = screenQuestions.first {
            processQuestion(question, source: .manual, screenContext: screenText)
            return
        }
        
        let audioQuestions = questionDetectionService.detectFromAudio(audioText)
        if let question = audioQuestions.first {
            processQuestion(question, source: .manual, screenContext: nil)
            return
        }
        
        // Fallback: use latest text as question
        if !audioText.isEmpty {
            processQuestion(audioText, source: .manual, screenContext: nil)
        } else if !screenText.isEmpty {
            processQuestion(screenText, source: .manual, screenContext: screenText)
        } else {
            print("⚠️ No text available to process as question")
        }
    }
    
    private func processDetectedQuestions(from text: String, source: QuestionSource, screenContext: String?) {
        let questions = questionDetectionService.detectQuestions(in: text)
        for question in questions {
            processQuestion(question, source: source, screenContext: screenContext)
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
                guard !chunk.isEmpty, self.isRunning else { return }
                buffer += chunk
                self.qaManager.updateAnswer(for: item.id, answer: buffer)
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

