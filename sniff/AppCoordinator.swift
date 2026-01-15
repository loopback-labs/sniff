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
    let qaManager = QAManager()
    let keychainService = KeychainService()
    
    private var perplexityService: PerplexityService?
    private var overlayWindow: NSWindow?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    
    @Published var isRunning = false
    @Published var automaticMode = true
    
    init() {
        setupPerplexityService()
        setupSubscriptions()
    }
    
    private func setupPerplexityService() {
        if let apiKey = keychainService.getAPIKey() {
            perplexityService = PerplexityService(apiKey: apiKey)
        }
    }
    
    private func setupSubscriptions() {
        screenCaptureService.$capturedText
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self = self, self.automaticMode, !text.isEmpty else { return }
                print("📺 Screen text captured: \(text.prefix(100))...")
                self.processDetectedQuestions(from: text, source: .screen, screenContext: text)
            }
            .store(in: &cancellables)
        
        audioCaptureService.$transcribedText
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self = self, self.automaticMode, !text.isEmpty else { return }
                print("🎤 Audio text: \(text)")
                self.processDetectedQuestions(from: text, source: .audio, screenContext: nil)
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
        
        // Request permissions
        await requestPermissions()
        
        // Start services
        do {
            try await screenCaptureService.startCapture()
            try audioCaptureService.startCapture()
            
            // Create overlay window
            createOverlayWindow()
            
            // Setup keyboard shortcuts
            setupKeyboardShortcuts()
            
            isRunning = true
        } catch {
            print("Failed to start services: \(error)")
        }
    }
    
    func stop() async {
        await screenCaptureService.stopCapture()
        audioCaptureService.stopCapture()
        
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        overlayWindow?.close()
        overlayWindow = nil
        
        isRunning = false
    }
    
    func requestPermissions() async {
        // Screen recording permission
        let screenPermission = await requestScreenRecordingPermission()
        if !screenPermission {
            print("Screen recording permission denied")
        }
        
        // Microphone permission is handled by AudioCaptureService
        // Speech recognition permission is handled by AudioCaptureService
    }
    
    private func requestScreenRecordingPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            let granted = CGRequestScreenCaptureAccess()
            continuation.resume(returning: granted)
        }
    }
    
    private func createOverlayWindow() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenRect = screen.frame
        
        let windowRect = NSRect(
            x: screenRect.maxX - 450,
            y: screenRect.maxY - 300,
            width: 420,
            height: 250
        )
        
        let window = OverlayWindow(
            contentRect: windowRect,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        
        let contentView = OverlayContentView(qaManager: qaManager)
            .environmentObject(self)
        
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        print("🪟 Overlay window created at: \(windowRect)")
        
        self.overlayWindow = window
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
            
            // Arrow keys: Navigate Q&A (only when overlay is key)
            if self.overlayWindow?.isKeyWindow == true {
                if event.keyCode == 123 { // Left arrow
                    self.qaManager.goToPrevious()
                    return
                } else if event.keyCode == 124 { // Right arrow
                    self.qaManager.goToNext()
                    return
                } else if event.keyCode == 126 && flags.contains(.command) { // Cmd+Up
                    self.qaManager.goToFirst()
                    return
                } else if event.keyCode == 125 && flags.contains(.command) { // Cmd+Down
                    self.qaManager.goToLast()
                    return
                } else if event.keyCode == 48 { // Tab
                    // Toggle question/answer view handled in QADisplayView
                    return
                }
            }
        }
    }
    
    func triggerManualQuestion() {
        print("🔘 Manual question triggered")
        let screenText = screenCaptureService.capturedText
        let audioText = audioCaptureService.transcribedText
        
        print("   Screen text: \(screenText.isEmpty ? "empty" : String(screenText.prefix(50)))")
        print("   Audio text: \(audioText.isEmpty ? "empty" : String(audioText.prefix(50)))")
        
        var question: String?
        var screenContext: String?
        
        if !screenText.isEmpty {
            question = firstQuestion(
                in: screenText,
                detector: questionDetectionService.detectFromScreen,
                label: "screen"
            )
            if question != nil {
                screenContext = screenText
            }
        }
        
        if question == nil && !audioText.isEmpty {
            question = firstQuestion(
                in: audioText,
                detector: questionDetectionService.detectFromAudio,
                label: "audio"
            )
        }
        
        // If no question detected, use the latest text as a question
        if question == nil {
            if !audioText.isEmpty {
                question = audioText
            } else if !screenText.isEmpty {
                question = screenText
                screenContext = screenText
            }
        }
        
        if let question = question {
            processQuestion(question, source: .manual, screenContext: screenContext)
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
        
        // Get answer from Perplexity
        Task {
            await getAnswer(for: item)
        }
    }

    private func firstQuestion(in text: String, detector: (String) -> [String], label: String) -> String? {
        let questions = detector(text)
        print("   Detected \(questions.count) questions from \(label)")
        return questions.first
    }

    private func isDuplicateRecent(_ question: String) -> Bool {
        let recentQuestions = qaManager.items.filter {
            abs($0.timestamp.timeIntervalSinceNow) < 30
        }
        return recentQuestions.contains { $0.question.lowercased() == question.lowercased() }
    }
    
    private func getAnswer(for item: QAItem) async {
        guard let perplexityService = perplexityService else {
            print("❌ No Perplexity service available")
            return
        }
        
        print("🔍 Requesting answer for: \(item.question)")
        
        do {
            let answer = try await perplexityService.answerQuestion(
                item.question,
                screenContext: item.screenContext
            )
            
            print("✅ Answer received: \(answer.prefix(100))...")
            
            await MainActor.run {
                qaManager.updateAnswer(for: item.id, answer: answer)
            }
        } catch {
            print("❌ Failed to get answer: \(error)")
            if let perplexityError = error as? PerplexityError {
                print("   Error details: \(perplexityError)")
            }
            await MainActor.run {
                qaManager.updateAnswer(for: item.id, answer: "Error: \(error.localizedDescription)")
            }
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
}

