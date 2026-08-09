import SwiftUI

import AppKit
import Combine
import CoreGraphics
import HotKey

@MainActor
class AppCoordinator: NSObject, ObservableObject {
    let screenCaptureService = ScreenCaptureService()
    let appPermissions = AppPermissions()
    let localWhisperService = LocalWhisperService()
    let parakeetService = ParakeetTranscriptionService()
    let audioDeviceService = AudioDeviceService()
    let questionDetectionService = QuestionDetectionService()
    let qaManager = QAManager()
    let transcriptBuffer = TranscriptBuffer()
    let keychainService = KeychainService()
    let chatGPTAuthManager = ChatGPTAuthManager()
    let modelDownloads = ModelDownloadManager()
    
    private var llmService: LLMService?
    private var qaOverlayWindow: NSWindow?
    private var transcriptOverlayWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var permissionOnboardingWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private var toggleHotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private let audioQuestionPipeline: AudioQuestionPipeline
    private let promptBuilder = PromptBuilder()
    private var isCaptureTransitioning = false

    @Published var isRunning = false
    @Published var selectedProvider: LLMProvider {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: UserDefaultsKeys.selectedLLMProvider)
            let next = LLMModelCatalog.loadOrDefaultModelId(for: selectedProvider)
            if next != selectedModelId {
                selectedModelId = next
            } else {
                rebuildLLMService()
            }
        }
    }

    @Published var selectedModelId: String = "" {
        didSet {
            guard !selectedModelId.isEmpty else { return }
            LLMModelCatalog.saveModelId(selectedModelId, for: selectedProvider)
            rebuildLLMService()
        }
    }
    @Published var selectedSpeechEngine: SpeechEngine {
        didSet {
            UserDefaults.standard.set(selectedSpeechEngine.rawValue, forKey: UserDefaultsKeys.selectedSpeechEngine)
            if isRunning {
                Task { await restartSpeechCapture() }
            }
        }
    }

    @Published var selectedParakeetModelChoice: ParakeetModelChoice {
        didSet {
            UserDefaults.standard.set(selectedParakeetModelChoice.rawValue, forKey: UserDefaultsKeys.selectedParakeetModelChoice)
            if isRunning && selectedSpeechEngine == .parakeet {
                Task { await restartSpeechCapture() }
            }
        }
    }

    /// Mirrors `selectedParakeetModelChoice` so both engines have one source of truth here rather
    /// than Settings and onboarding each keeping their own `@State` copy alongside UserDefaults.
    @Published var selectedWhisperModelID: String {
        didSet {
            UserDefaults.standard.set(selectedWhisperModelID, forKey: UserDefaultsKeys.whisperModelId)
            if isRunning && selectedSpeechEngine == .whisper {
                Task { await restartSpeechCapture() }
            }
        }
    }
    @Published var showOverlay: Bool {
        didSet {
            UserDefaults.standard.set(showOverlay, forKey: UserDefaultsKeys.showOverlay)
            updateOverlayVisibility()
        }
    }
    /// Whether the selected provider can actually be called: a key in the Keychain, or a live
    /// ChatGPT session. Published so the onboarding AI step enables "Continue" the moment a key is
    /// saved, and recomputed in `rebuildLLMService()` — the one funnel every credential change
    /// already goes through.
    @Published private(set) var hasLLMCredential = false

    @Published var askComposerFocusToken = UUID()
    @Published var isAskComposerFocused = false
    @Published var overlaysForceInteractive = false

    /// True when capture started but ScreenCaptureKit wouldn't give us system audio, so only the
    /// microphone is being transcribed. Surfaced in the transcript overlay — this used to be a
    /// `print`, which meant the other side of a call silently never appeared.
    @Published private(set) var systemAudioUnavailable = false
    /// Why system audio is unavailable, shown in the overlay banner so the fix is actionable.
    @Published private(set) var systemAudioFailureReason: String?
    /// Mirrors the active engine's microphone peak so the overlay can show input is arriving.
    @Published private(set) var micLevel: Float = 0

    private var clickThroughTimer: Timer?

    /// Where session transcripts are written. Surfaced in Settings > General.
    static let transcriptSaveDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .appendingPathComponent("sniff-transcripts")


    override init() {
        let savedProvider = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedLLMProvider) ?? LLMProvider.openai.rawValue
        let initialLLMProvider = LLMProvider(rawValue: savedProvider) ?? .openai
        selectedProvider = initialLLMProvider
        showOverlay = UserDefaults.standard.object(forKey: UserDefaultsKeys.showOverlay) as? Bool ?? true
        let savedSpeechEngine = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedSpeechEngine) ?? SpeechEngine.whisper.rawValue
        selectedSpeechEngine = SpeechEngine(rawValue: savedSpeechEngine) ?? .whisper
        let savedParakeetModel = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedParakeetModelChoice) ?? ParakeetModelChoice.eou320ms.rawValue
        selectedParakeetModelChoice = ParakeetModelChoice(rawValue: savedParakeetModel) ?? .eou320ms
        selectedWhisperModelID = LocalWhisperService.currentSelectedModelID()
        
        audioQuestionPipeline = AudioQuestionPipeline(questionDetectionService: questionDetectionService)

        selectedModelId = LLMModelCatalog.loadOrDefaultModelId(for: initialLLMProvider)

        super.init()

        rebuildLLMService()
        applySavedAudioInputDevice()

        toggleHotKey = HotKey(key: .w, modifiers: [.command, .shift])
        toggleHotKey?.keyDownHandler = { [weak self] in
            self?.toggle()
        }
    }
    
    private func applySavedAudioInputDevice() {
        guard let savedUID = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedAudioInputDeviceUID) else { return }
        do {
            try audioDeviceService.setDefaultInputDevice(byUID: savedUID)
        } catch {
            print("Failed to restore saved audio input device: \(error)")
        }
    }
    
    func rebuildLLMService() {
        llmService = LLMServiceFactory.makeService(
            provider: selectedProvider,
            modelId: resolvedModelId(),
            keychain: keychainService,
            chatGPTAuth: chatGPTAuthManager
        )
        hasLLMCredential = selectedProvider.usesOAuth
            ? chatGPTAuthManager.isSignedIn
            : !(keychainService.getAPIKey(for: selectedProvider) ?? "").isEmpty
    }

    private func resolvedModelId() -> String {
        selectedModelId.isEmpty
            ? LLMModelCatalog.loadOrDefaultModelId(for: selectedProvider)
            : selectedModelId
    }

    private struct SpeechEngineRouting {
        let sourcePublishers: [(speaker: TranscriptSpeaker, publisher: AnyPublisher<TranscriptionUpdate, Never>)]
        let micLevelPublisher: AnyPublisher<Float, Never>
        let startCapture: () async throws -> Void
    }

    private func speechRouting(for engine: SpeechEngine) -> SpeechEngineRouting {
        switch engine {
        case .whisper:
            return SpeechEngineRouting(
                sourcePublishers: [
                    (.you, localWhisperService.$micUpdate.eraseToAnyPublisher()),
                    (.others, localWhisperService.$systemUpdate.eraseToAnyPublisher())
                ],
                micLevelPublisher: localWhisperService.$micLevel.eraseToAnyPublisher(),
                startCapture: { [weak self] in
                    guard let self else { throw CancellationError() }
                    self.configureWhisperService()
                    try await self.localWhisperService.startCapture()
                }
            )
        case .parakeet:
            return SpeechEngineRouting(
                sourcePublishers: [
                    (.you, parakeetService.$micUpdate.eraseToAnyPublisher()),
                    (.others, parakeetService.$systemUpdate.eraseToAnyPublisher())
                ],
                micLevelPublisher: parakeetService.$micLevel.eraseToAnyPublisher(),
                startCapture: { [weak self] in
                    guard let self else { throw CancellationError() }
                    self.configureParakeetService()
                    try await self.parakeetService.startCapture()
                }
            )
        }
    }

    private func currentTranscribedText() -> String {
        let text = transcriptBuffer.recentTextForDetection()
        return stripSpeakerLabels(from: text)
    }

    private func startSpeechCapture(using engine: SpeechEngine) async throws {
        try await speechRouting(for: engine).startCapture()
    }

    private func stopSpeechCapture(finalizeSystem: Bool) async {
        await localWhisperService.stopCapture(finalizeSystem: finalizeSystem)
        await parakeetService.stopCapture(finalizeSystem: finalizeSystem)
    }

    private func restartSpeechCapture() async {
        guard isRunning else { return }
        guard !isCaptureTransitioning else { return }
        isCaptureTransitioning = true
        defer { isCaptureTransitioning = false }

        let engineForSystemAudio = selectedSpeechEngine
        await stopSpeechCapture(finalizeSystem: false)
        await screenCaptureService.stopCapture()
        localWhisperService.reset()
        await parakeetService.reset()
        cancellables.removeAll()
        setupSubscriptions()
        do {
            try await startSpeechCapture(using: engineForSystemAudio)
            do {
                try await screenCaptureService.startCapture(
                    enableSystemAudio: true,
                    audioSampleHandler: makeSystemAudioHandler(for: engineForSystemAudio)
                )
                systemAudioUnavailable = false
                systemAudioFailureReason = nil
            } catch {
                print("⚠️ System audio capture unavailable after restart; continuing with microphone-only transcription: \(error)")
                systemAudioUnavailable = true
                systemAudioFailureReason = error.localizedDescription
            }
        } catch {
            print("Failed to restart speech capture: \(error)")
            presentStartFailure(error)
            await stop()
        }
    }

    private func configureWhisperService() {
        localWhisperService.configure(modelID: selectedWhisperModelID)
    }

    private func configureParakeetService() {
        parakeetService.configure(modelChoice: selectedParakeetModelChoice)
    }

    private func setupSubscriptions() {
        let routing = speechRouting(for: selectedSpeechEngine)
        let sourcePublishers = routing.sourcePublishers

        routing.micLevelPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.micLevel = level }
            .store(in: &cancellables)

        let mergedPublisher = Publishers.MergeMany(sourcePublishers.map { $0.publisher })
            .receive(on: RunLoop.main)
            .share()

        sourcePublishers.forEach { source in
            source.publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] update in
                    guard let self = self else { return }
                    if update.isFinal {
                        self.transcriptBuffer.commitPending(text: update.text, speaker: source.speaker)
                    } else {
                        self.transcriptBuffer.updatePending(text: update.text, speaker: source.speaker)
                    }
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

                if let latestQuestion = result.latestQuestion {
                    print("🔍 Detected audio question: \(latestQuestion.prefix(50))...")
                }
                self.transcriptBuffer.updateLatestQuestion(result.latestQuestion)
            }
            .store(in: &cancellables)
    }

    private func stripSpeakerLabels(from text: String) -> String {
        text.replacingOccurrences(
            of: #"\[(You|Others)\]\s*"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSystemAudioHandler(for engine: SpeechEngine) -> @Sendable ([Float]) -> Void {
        switch engine {
        case .whisper:
            let service = localWhisperService
            return { floats in
                Task { @MainActor in service.appendSystemAudioFloats(floats) }
            }
        case .parakeet:
            let service = parakeetService
            return { floats in
                Task { @MainActor in service.appendSystemAudioFloats(floats) }
            }
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
        guard !isCaptureTransitioning else { return }
        isCaptureTransitioning = true
        defer { isCaptureTransitioning = false }

        guard llmService != nil else {
            showSettingsWindow()
            return
        }

        guard await requestPermissions() else { return }
        
        transcriptBuffer.clear()
        localWhisperService.reset()
        await parakeetService.reset()
        systemAudioUnavailable = false
        systemAudioFailureReason = nil
        micLevel = 0
        transcriptBuffer.startSession(saveDirectoryURL: Self.transcriptSaveDirectory)
        audioQuestionPipeline.reset()
        setupSubscriptions()

        do {
            try await startSpeechCapture(using: selectedSpeechEngine)
            do {
                try await screenCaptureService.startCapture(
                    enableSystemAudio: true,
                    audioSampleHandler: makeSystemAudioHandler(for: selectedSpeechEngine)
                )
                systemAudioUnavailable = false
                systemAudioFailureReason = nil
            } catch {
                print("⚠️ Screen/system audio capture unavailable; continuing with microphone-only transcription: \(error)")
                systemAudioUnavailable = true
                systemAudioFailureReason = error.localizedDescription
            }

            createQAOverlayWindow()
            createTranscriptOverlayWindow()
            setupKeyboardShortcuts()
            startClickThroughTracking()
            isRunning = true
        } catch {
            print("Failed to start services: \(error)")
            await screenCaptureService.stopCapture()
            await stopSpeechCapture(finalizeSystem: false)
            cancellables.removeAll()
            transcriptBuffer.stopSession()
            // Previously this failed silently: the menu item flipped back to "Start" with no
            // explanation, which is indistinguishable from transcription just not working.
            presentStartFailure(error)
        }
    }

    /// Surfaces a hard capture-startup failure. Model load errors, a missing input device, or a
    /// revoked permission all land here, and all of them look like "nothing happens" otherwise.
    private func presentStartFailure(_ error: Error) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sniff couldn't start listening"
        alert.informativeText = """
            \(error.localizedDescription)

            Check the transcription model and input device in Settings, then try again.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            showSettingsWindow()
        }
    }
    
    func stop() async {
        guard isRunning else { return }
        guard !isCaptureTransitioning else { return }
        isCaptureTransitioning = true
        defer { isCaptureTransitioning = false }

        await screenCaptureService.stopCapture()
        await stopSpeechCapture(finalizeSystem: true)
        cancellables.removeAll()
        transcriptBuffer.stopSession()

        hotKeys.removeAll()

        clickThroughTimer?.invalidate()
        clickThroughTimer = nil

        for window in [qaOverlayWindow, transcriptOverlayWindow] {
            window?.ignoresMouseEvents = true
            window?.contentView = nil
            window?.orderOut(nil)
        }
        qaOverlayWindow = nil
        transcriptOverlayWindow = nil
        
        isRunning = false
    }
    
    /// The model the selected engine will actually load, across both engines.
    var selectedSpeechModel: SpeechModel {
        switch selectedSpeechEngine {
        case .whisper: return .whisper(selectedWhisperModelID)
        case .parakeet: return .parakeet(selectedParakeetModelChoice)
        }
    }

    /// Both engines now require an explicit model download (Settings > Speech, or the
    /// transcription-model onboarding step) before capture can start.
    func needsTranscriptionModelSetup() -> Bool {
        switch selectedSpeechEngine {
        case .whisper:
            return !LocalWhisperService.listDownloadedModels().contains(selectedWhisperModelID)
        case .parakeet:
            return !ParakeetTranscriptionService.isDownloaded(selectedParakeetModelChoice)
        }
    }

    func onboardingReadiness() -> OnboardingReadiness {
        OnboardingReadiness(
            permissionsGranted: appPermissions.allGranted,
            speechModelInstalled: !needsTranscriptionModelSetup(),
            llmCredentialReady: hasLLMCredential
        )
    }

    var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.onboardingCompleted)
    }

    /// Onboarding is due until the user has walked the flow once, even if permissions and a model
    /// happen to be in place — that's what gets a new user to the AI-provider step instead of
    /// discovering the gap when their first question fails.
    var needsOnboarding: Bool {
        !appPermissions.allGranted || needsTranscriptionModelSetup() || !hasCompletedOnboarding
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.onboardingCompleted)
    }

    /// Capture itself only needs permissions and a speech model — a missing API key is recoverable
    /// (transcripts still work), so it doesn't block starting a session.
    func requestPermissions() async -> Bool {
        await appPermissions.refreshAccurate()
        if appPermissions.allGranted && !needsTranscriptionModelSetup() { return true }
        presentPermissionOnboardingWindow()
        return false
    }

    func evaluatePermissionOnboardingAtLaunch() async {
        // Give TCC daemon extra time to initialise on macOS 26 before querying.
        try? await Task.sleep(for: .milliseconds(500))
        await appPermissions.refreshAccurate()
        modelDownloads.refreshInstalled()

        // Installs that were already fully configured before this flow existed shouldn't be walked
        // through it — mark them done rather than interrupting a working setup.
        if !hasCompletedOnboarding && onboardingReadiness().isComplete {
            completeOnboarding()
        }

        if needsOnboarding {
            presentPermissionOnboardingWindow()
        } else {
            dismissOnboardingIfComplete()
        }
    }

    func presentPermissionOnboardingWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let existing = permissionOnboardingWindow, existing.isVisible {
            existing.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up Sniff"
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Not wrapped in a ScrollView: the model step hosts a grouped Form, which is already its
        // own scroll container and lays out badly when nested inside another one.
        let root = OnboardingContainerView(coordinator: self) { [weak self] in
            self?.finishOnboarding()
        }
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.orderFrontRegardless()
        permissionOnboardingWindow = window
    }

    func finishOnboarding() {
        permissionOnboardingWindow?.close()
        permissionOnboardingWindow = nil
    }

    /// Closes the window when it was only up as a permission nag. Once the flow itself is running,
    /// granting a permission advances a step instead of yanking the window away mid-setup.
    func dismissOnboardingIfComplete() {
        guard hasCompletedOnboarding, !needsOnboarding else { return }
        permissionOnboardingWindow?.close()
        permissionOnboardingWindow = nil
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
                .environmentObject(self)
        }
    }
    
    private func createWindow<Content: View>(config: WindowConfiguration, @ViewBuilder content: () -> Content) -> NSWindow {
        let window = OverlayWindow(config: config)
        window.setScreenshotInclusion(showOverlay)
        let hostingView = NSHostingView(rootView: content().environment(\.overlayWindow, window))
        // Keep the window at its configured size instead of letting SwiftUI's fitting size drive
        // it. With the default sizing options, wrapping text measured against an unconstrained
        // width reports an enormous height and the overlay grows far past its `WindowConfiguration`
        // (the transcript window was resizing itself to thousands of points tall).
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        print("🪟 \(config.name) overlay window created at: \(window.frame)")
        return window
    }
    
    /// Keep `AppShortcut.all` in sync with the bindings registered here — it's what Settings >
    /// Shortcuts displays.
    private func setupKeyboardShortcuts() {
        hotKeys.removeAll()

        let screenQuestionHotKey = HotKey(key: .q, modifiers: [.command, .shift])
        screenQuestionHotKey.keyDownHandler = { [weak self] in
            self?.triggerScreenQuestion()
        }
        hotKeys.append(screenQuestionHotKey)

        let audioQuestionHotKey = HotKey(key: .a, modifiers: [.command, .shift])
        audioQuestionHotKey.keyDownHandler = { [weak self] in
            self?.triggerAudioQuestion()
        }
        hotKeys.append(audioQuestionHotKey)

        let optionLeftKey = HotKey(key: .leftArrow, modifiers: [.option])
        optionLeftKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true, !self.isAskComposerFocused else { return }
            self.qaManager.goToPrevious()
        }
        hotKeys.append(optionLeftKey)

        let optionRightKey = HotKey(key: .rightArrow, modifiers: [.option])
        optionRightKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true, !self.isAskComposerFocused else { return }
            self.qaManager.goToNext()
        }
        hotKeys.append(optionRightKey)

        let optionUpKey = HotKey(key: .upArrow, modifiers: [.option])
        optionUpKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true, !self.isAskComposerFocused else { return }
            self.qaManager.goToFirst()
        }
        hotKeys.append(optionUpKey)

        let optionDownKey = HotKey(key: .downArrow, modifiers: [.option])
        optionDownKey.keyDownHandler = { [weak self] in
            guard let self = self, self.qaOverlayWindow?.isKeyWindow == true, !self.isAskComposerFocused else { return }
            self.qaManager.goToLast()
        }
        hotKeys.append(optionDownKey)

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

        let sayNextHotKey = HotKey(key: .s, modifiers: [.command, .shift])
        sayNextHotKey.keyDownHandler = { [weak self] in
            self?.runMode(.sayNext)
        }
        hotKeys.append(sayNextHotKey)

        let followUpsHotKey = HotKey(key: .f, modifiers: [.command, .shift])
        followUpsHotKey.keyDownHandler = { [weak self] in
            self?.runMode(.followUps)
        }
        hotKeys.append(followUpsHotKey)

        let recapHotKey = HotKey(key: .e, modifiers: [.command, .shift])
        recapHotKey.keyDownHandler = { [weak self] in
            self?.runMode(.recap)
        }
        hotKeys.append(recapHotKey)

        let askComposerHotKey = HotKey(key: .k, modifiers: [.command, .shift])
        askComposerHotKey.keyDownHandler = { [weak self] in
            self?.focusAskComposer()
        }
        hotKeys.append(askComposerHotKey)

        let clickThroughHotKey = HotKey(key: .i, modifiers: [.command, .shift])
        clickThroughHotKey.keyDownHandler = { [weak self] in
            self?.overlaysForceInteractive.toggle()
        }
        hotKeys.append(clickThroughHotKey)
    }

    /// Starts a ~20 Hz cursor poll (no accessibility permission needed) that flips each overlay
    /// window's click-through state based on whether the cursor is over a registered control.
    private func startClickThroughTracking() {
        clickThroughTimer?.invalidate()
        clickThroughTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateClickThrough()
            }
        }
    }

    private func updateClickThrough() {
        // Skip mid-gesture so an in-progress drag/resize never has the flag flip under it.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let mouseLocation = NSEvent.mouseLocation
        for window in [qaOverlayWindow, transcriptOverlayWindow] {
            (window as? OverlayWindow)?.refreshClickThrough(
                mouseScreenPoint: mouseLocation,
                forceInteractive: overlaysForceInteractive
            )
        }
    }

    func triggerScreenQuestion() {
        print("🖥️ Screen question triggered")
        runMode(.solveScreen)
    }

    func triggerAudioQuestion() {
        print("🎙️ Audio question triggered")
        runMode(.answerQuestion)
    }

    func focusAskComposer() {
        qaOverlayWindow?.makeKeyAndOrderFront(nil)
        askComposerFocusToken = UUID()
    }

    /// Central entry point for every prompting mode (detected question, screenshot solve, say-next,
    /// follow-ups, recap, typed ask). Builds context-aware prompts via `PromptBuilder` and streams
    /// the answer through the currently selected provider.
    func runMode(_ mode: PromptMode, typedText: String? = nil) {
        switch mode {
        case .answerQuestion:
            let audioText = currentTranscribedText()
            print("   Audio text: \(audioText.isEmpty ? "empty" : String(audioText.prefix(50)))")
            guard let question = resolveAudioQuestion(from: audioText) else { return }
            guard !isDuplicateRecent(question) else {
                print("⚠️ Duplicate question detected, skipping: \(question)")
                return
            }
            startMode(mode, bubbleText: question, source: mode.questionSource, detectedQuestion: question)

        case .solveScreen:
            Task {
                guard let imageData = await captureImageIfNeeded(for: mode) else {
                    print("⚠️ No screenshot available")
                    return
                }
                print("   Screenshot available: \(imageData.count) bytes")
                startMode(mode, bubbleText: mode.displayBubble ?? "", source: mode.questionSource, imageDataTask: Task { imageData })
            }

        case .sayNext, .followUps, .recap:
            startMode(mode, bubbleText: mode.displayBubble ?? "", source: mode.questionSource)

        case .ask:
            let text = (typedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let imageDataTask = Task { await captureImageIfNeeded(for: mode) }
            startMode(mode, bubbleText: text, source: mode.questionSource, typedText: text, imageDataTask: imageDataTask)
        }
    }

    /// Resolves screenshot data according to the mode's `imageCapture` policy: unconditional capture
    /// for modes that require one, vision-gated opportunistic capture for modes that use it if available.
    private func captureImageIfNeeded(for mode: PromptMode) async -> Data? {
        switch mode.imageCapture {
        case .none:
            return nil
        case .required:
            return await screenCaptureService.captureCurrentFrame()
        case .whenVisionSupported:
            guard modelSupportsVision() else { return nil }
            return await screenCaptureService.captureCurrentFrame()
        }
    }

    private func resolveAudioQuestion(from audioText: String) -> String? {
        if let latestQuestion = transcriptBuffer.latestQuestion {
            print("   Using latest detected question: \(latestQuestion.prefix(50))...")
            return latestQuestion
        }

        guard !audioText.isEmpty else {
            print("⚠️ No audio text available to process as question")
            return nil
        }

        if let question = questionDetectionService.firstQuestion(in: audioText) {
            print("   Detected question: \(question.prefix(50))...")
            return question
        }

        print("   No question detected, using raw audio text as fallback")
        return audioText
    }

    private func startMode(
        _ mode: PromptMode,
        bubbleText: String,
        source: QuestionSource,
        detectedQuestion: String? = nil,
        typedText: String? = nil,
        imageDataTask: Task<Data?, Never>? = nil
    ) {
        print("▶️ Running mode \(mode) (\(source)): \(bubbleText.prefix(50))")
        let item = qaManager.addQuestion(bubbleText, source: source)
        // Built synchronously here so it runs concurrently with any in-flight screenshot capture
        // rather than waiting for it first.
        let payload = promptBuilder.build(
            mode: mode,
            transcript: transcriptBuffer,
            qaHistory: Array(qaManager.items.suffix(20)),
            detectedQuestion: detectedQuestion,
            typedText: typedText
        )
        Task {
            let imageData = await imageDataTask?.value
            await getAnswer(for: item, payload: payload, imageData: imageData)
        }
    }

    private func modelSupportsVision() -> Bool {
        LLMModelCatalog.supportsVision(provider: selectedProvider, modelId: resolvedModelId())
    }

    private func isDuplicateRecent(_ question: String) -> Bool {
        let recentQuestions = qaManager.items.filter {
            abs($0.timestamp.timeIntervalSinceNow) < 30
        }
        return recentQuestions.contains { $0.question.lowercased() == question.lowercased() }
    }

    private func getAnswer(for item: QAItem, payload: PromptPayload, imageData: Data? = nil) async {
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
                guard modelSupportsVision() else {
                    throw LLMError.imageInputNotSupportedByModel(resolvedModelId())
                }
                answer = try await llmService.streamAnswerWithImage(
                    userMessage: payload.userMessage,
                    systemPrompt: payload.systemPrompt,
                    imageData: imageData,
                    options: payload.options,
                    onChunk: onChunk
                )
            } else {
                answer = try await llmService.streamAnswer(
                    userMessage: payload.userMessage,
                    systemPrompt: payload.systemPrompt,
                    options: payload.options,
                    onChunk: onChunk
                )
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

        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
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
        guard !provider.usesOAuth else { return }
        do {
            try keychainService.saveAPIKey(key, for: provider)
            if provider == selectedProvider {
                rebuildLLMService()
            }
        } catch {
            print("Failed to update API key: \(error)")
        }
    }

    func refreshLLMAfterChatGPTAuth() {
        objectWillChange.send()
        rebuildLLMService()
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

extension AppCoordinator: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow,
              let current = permissionOnboardingWindow,
              closed === current else { return }
        permissionOnboardingWindow = nil
    }
}
