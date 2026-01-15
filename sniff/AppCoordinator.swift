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

@MainActor
class AppCoordinator: ObservableObject {
    let screenCaptureService = ScreenCaptureService()
    let audioCaptureService = AudioCaptureService()
    let questionDetectionService = QuestionDetectionService()
    let technicalQuestionClassifier = TechnicalQuestionClassifier()
    let qaManager = QAManager()
    let transcriptBuffer = TranscriptBuffer()
    let keychainService = KeychainService()
    
    private var perplexityService: PerplexityService?
    private var qaOverlayWindow: NSWindow?
    private var transcriptOverlayWindow: NSWindow?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let transcriptionDeltaProcessor = TranscriptionDeltaProcessor()
    
    @Published var isRunning = false
    @Published var automaticMode = true
    @Published var showOverlay: Bool {
        didSet {
            UserDefaults.standard.set(showOverlay, forKey: "showOverlay")
            updateOverlayVisibility()
        }
    }
    
    init() {
        showOverlay = UserDefaults.standard.object(forKey: "showOverlay") as? Bool ?? true
        if let apiKey = keychainService.getAPIKey() {
            perplexityService = PerplexityService(apiKey: apiKey)
        }
        setupSubscriptions()
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
        guard perplexityService != nil else {
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
        
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
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
        let config = WindowConfig(
            widthRatio: 0.4, maxWidth: 800,
            heightRatio: 0.6, maxHeight: 600,
            xOffset: -20, yOffset: -20,
            minSize: NSSize(width: 380, height: 200),
            maxSizeRatio: (0.8, 0.9),
            position: .topRight
        )
        qaOverlayWindow = createOverlayWindow(
            config: config,
            contentView: OverlayContentView(qaManager: qaManager).environmentObject(self),
            name: "Q&A"
        )
    }

    private func createTranscriptOverlayWindow() {
        let config = WindowConfig(
            widthRatio: 0.35, maxWidth: 600,
            heightRatio: 0.4, maxHeight: 500,
            xOffset: 20, yOffset: -20,
            minSize: NSSize(width: 350, height: 80),
            maxSizeRatio: (0.7, 0.8),
            position: .topLeft
        )
        transcriptOverlayWindow = createOverlayWindow(
            config: config,
            contentView: TranscriptOverlayView(transcriptBuffer: transcriptBuffer),
            name: "Transcript"
        )
    }
    
    private struct WindowConfig {
        let widthRatio: CGFloat
        let maxWidth: CGFloat
        let heightRatio: CGFloat
        let maxHeight: CGFloat
        let xOffset: CGFloat
        let yOffset: CGFloat
        let minSize: NSSize
        let maxSizeRatio: (CGFloat, CGFloat)
        let position: WindowPosition
    }
    
    private enum WindowPosition {
        case topLeft, topRight
    }
    
    private func createOverlayWindow(config: WindowConfig, contentView: some View, name: String) -> NSWindow {
        let screenRect = (NSScreen.main ?? NSScreen.screens.first!).visibleFrame
        let width = min(screenRect.width * config.widthRatio, config.maxWidth)
        let height = min(screenRect.height * config.heightRatio, config.maxHeight)
        
        let x = config.position == .topLeft
            ? screenRect.minX + config.xOffset
            : screenRect.maxX - width + config.xOffset
        
        let rect = NSRect(
            x: x,
            y: screenRect.maxY - height + config.yOffset,
            width: width,
            height: height
        )
        
        let window = OverlayWindow(contentRect: rect)
        window.minSize = config.minSize
        window.maxSize = NSSize(
            width: screenRect.width * config.maxSizeRatio.0,
            height: screenRect.height * config.maxSizeRatio.1
        )
        window.setScreenshotInclusion(showOverlay)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        print("🪟 \(name) overlay window created at: \(rect)")
        return window
    }
    
    private func setupKeyboardShortcuts() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return }
            
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            
            // Cmd+Shift+Q: Manual question trigger
            if flags == [.command, .shift] && event.keyCode == 12 {
                self.triggerManualQuestion()
                return
            }
            
            // Navigation keys (only when overlay is key)
            guard self.qaOverlayWindow?.isKeyWindow == true else { return }
            
            switch event.keyCode {
            case 123: // Left arrow
                self.qaManager.goToPrevious()
            case 124: // Right arrow
                self.qaManager.goToNext()
            case 126 where flags.contains(.command): // Cmd+Up
                self.qaManager.goToFirst()
            case 125 where flags.contains(.command): // Cmd+Down
                self.qaManager.goToLast()
            case 48: // Tab (handled in QADisplayView)
                break
            default:
                break
            }
        }
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
        guard isRunning, let perplexityService = perplexityService else {
            print("❌ No Perplexity service available or app stopped")
            qaManager.updateAnswer(for: item.id, answer: "Error: Missing API key or app stopped")
            return
        }
        
        print("🔍 Requesting answer for: \(item.question)")
        
        do {
            var buffer = ""
            guard isRunning else { return }
            qaManager.updateAnswer(for: item.id, answer: "")

            let answer = try await perplexityService.streamAnswer(
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
            if let perplexityError = error as? PerplexityError {
                print("   Error details: \(perplexityError)")
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
    
    func updateAPIKey(_ key: String) {
        do {
            try keychainService.saveAPIKey(key)
            perplexityService = PerplexityService(apiKey: key)
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

