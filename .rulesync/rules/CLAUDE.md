---
root: true
targets:
  - '*'
globs:
  - '**/*'
---
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## General Instructions:

- Follow YAGNI principles, only implement features when they are needed, use existing battle-tested libraries where possible
- Avoid long comments, on comment the WHY, not the WHAT
- Avoid very thin wrapper functions

## What this is

Sniff is a macOS menu bar app (SwiftUI/AppKit) that captures screen + audio during calls/interviews and streams LLM-generated answers into draggable overlay windows. See `README.md` for the full feature/permissions/usage rundown — don't duplicate it here.

## Commands

Build and run via Xcode (`open sniff.xcodeproj`, scheme **sniff**, ⌘R) — this is the primary workflow for UI/behavior changes since the app needs real screen/mic/system-audio permissions.

Command line:
```bash
# Build (Debug)
xcodebuild -project sniff.xcodeproj -scheme sniff -configuration Debug build

# Unit tests only — prefer this while iterating
xcodebuild test -project sniff.xcodeproj -scheme sniff -destination 'platform=macOS' -only-testing:sniffTests

# Everything, including the two UI tests
xcodebuild test -project sniff.xcodeproj -scheme sniff -destination 'platform=macOS'

# Run a single test
xcodebuild test -project sniff.xcodeproj -scheme sniff -destination 'platform=macOS' \
  -only-testing:sniffTests/sniffTests/promptBuilderUsesEmptyTranscriptFallback

# Release build + install to /Applications
./build-and-install.sh
```

Unit tests live in a single file, `sniffTests/sniffTests.swift`, using Swift Testing (`@Test`/`#expect`, not XCTest) and `@testable import Sniff` (note capital S — the module name, distinct from the `sniff` target/scheme). `sniffUITests/` holds one XCTest launch smoke test — the only coverage of `AppCoordinator.init()` and `AppDelegate`, since no unit test constructs either. It needs a GUI session and adds ~11s, so use `-only-testing:sniffTests` while iterating. There is no CI test job; `.github/workflows/release.yml` only builds and packages a DMG on manual dispatch.

Direct SPM dependencies (resolved into the Xcode project, no `Package.swift` at the root): `HotKey` (global shortcuts), `FluidAudio` (Parakeet on-device transcription), `argmax-oss-swift` (WhisperKit), `textual` (Markdown rendering). `Package.resolved` also lists `swiftui-math`, `swift-argument-parser`, and `swift-concurrency-extras` — those are transitive and not imported by app code.

## Architecture

`AppCoordinator` (`sniff/AppCoordinator.swift`) is the app's single orchestrator — a `@MainActor` `ObservableObject` owning every service, both overlay windows, hotkeys, and the `@Published` settings that drive UI. Almost everything routes through it; read it first when tracing a feature end to end.

### Prompting pipeline (the core flow)

1. **Capture** — `ScreenCaptureService` (screenshots + system audio) and the selected speech engine (`LocalWhisperService` or `ParakeetTranscriptionService`) publish `TranscriptionUpdate` values (`text` + `isFinal`) on `$micUpdate` / `$systemUpdate`.
2. **Transcript assembly** — streaming ASR revises its own output as more audio arrives, so `text` is the *full current utterance*, never a delta. `AppCoordinator.setupSubscriptions()` routes each update by `isFinal`: `TranscriptBuffer.updatePending` replaces that speaker's in-progress text wholesale, `commitPending` finalizes it (extracting sentences, persisting each, committing any trailing remainder). Both are keyed by `TranscriptSpeaker` (`.you` / `.others`).
3. **Question detection** — the merged update stream drives two timers: a 250 ms throttle calling `TranscriptBuffer.refreshDisplay()`, and a 1 s debounce that runs `recentTextForDetection()` (minus speaker labels) through `AudioQuestionPipeline` (wrapping `QuestionDetectionService`) and stores the hit via `updateLatestQuestion` for transcript-view highlighting.
4. **Trigger** — a hotkey, menu action, or typed message calls `AppCoordinator.runMode(_:)` with a `PromptMode` (`answerQuestion`, `solveScreen`, `sayNext`, `followUps`, `recap`, `ask`). This is the single entry point for every prompting flow.
5. **Prompt assembly** — `PromptBuilder` turns the mode + `TranscriptBuffer` + recent `QAItem` history into a `PromptPayload` (system prompt, user message, `LLMRequestOptions`). Per-mode behavior — transcript char budget, whether Q&A history is included, whether a screenshot is required/optional, the token limit — is all declared as properties on `PromptMode` itself (`sniff/Models/PromptMode.swift`); add new modes there rather than branching in `AppCoordinator`.
6. **LLM call** — `LLMServiceFactory` picks a concrete `LLMService` (`OpenAIService`, `ClaudeService`, `GeminiService`, `ChatGPTService`) based on `selectedProvider`, reading API keys from `KeychainService` (or the OAuth session from `ChatGPTAuthManager` for ChatGPT). All non-ChatGPT services subclass `BaseLLMService`, which implements the shared SSE streaming loop (`performStreamRequest`) — subclasses only need to override request-body building and stream-line parsing.
7. **Streaming to UI** — chunks flow back through an `onChunk` closure into `QAManager`, which owns the `QAItem` list the Q&A overlay renders and supports history navigation (⌥←/→/↑/↓).

### Models and per-model capabilities

`LLMModelCatalog` (`sniff/Models/LLMModelCatalog.swift`) is the single source of truth for which models each provider offers and what each one supports (`supportsVision`, `supportsThinkingLevel`). Services receive an `LLMModelOption` rather than a bare id string and gate request fields on its flags — that's how Claude Haiku 4.5 is excluded from the effort parameter it rejects. Add or retire models here, not in the services.

Current models are all reasoning models, which changes the request shape: no sampling parameters (`temperature` etc. are rejected on Claude Sonnet 5 / Opus 5 and GPT-5.6), OpenAI needs `max_completion_tokens` rather than `max_tokens`, and reasoning depth is a user setting. `ThinkingLevel` (Low/Medium/High, default High) is persisted per provider and maps to each API's own parameter — Anthropic `output_config.effort` + `thinking: {"type": "adaptive"}`, OpenAI `reasoning_effort`, ChatGPT `reasoning.effort`, Gemini `thinkingConfig.thinkingLevel`.

### Settings

User settings are `@Published` properties on `AppCoordinator` with a `didSet` that writes to `UserDefaults` and triggers the relevant side effect (`rebuildLLMService()`, `restartSpeechCapture()`, …). Keys live in `UserDefaultsKeys`; per-provider values use a prefix + `provider.rawValue`. Initial values are read in `init()` before `super.init()`. Provider/model/thinking rows live in `LLMSetupSections`, which `SettingsView`'s AI tab and the onboarding AI step both host, so the two never drift.

### Overlays

`OverlayWindow` (`sniff/Views/OverlayWindow.swift`) is a borderless, click-through-until-hovered `NSWindow`; `WindowConfiguration` (`sniff/Models/WindowConfiguration.swift`) declares fixed placement/size for the two overlays (Q&A top-right, transcript top-left). `AppCoordinator.startClickThroughTracking()` polls the cursor at ~20Hz (no Accessibility permission needed) to flip each window's click-through state — mid-drag/resize gestures are protected from having the flag flip under them.

### Speech engines

Two on-device engines are swappable at runtime via `selectedSpeechEngine`: `LocalWhisperService` (WhisperKit) and `ParakeetTranscriptionService` (FluidAudio). `AppCoordinator.speechRouting(for:)` is the one place that maps an engine to its update publishers, mic-level publisher, and capture-start closure — extend it there when adding a new engine rather than scattering `switch selectedSpeechEngine` elsewhere. Downloads for both engines' models are owned app-wide by `ModelDownloadManager` so progress survives Settings tab switches.

## Conventions

- SwiftUI for all new UI code.
- Indentation is mixed: most of the codebase is 4-space, some newer `Models/` and `Views/` files are 2-space. Match the file you're editing rather than reformatting it.
- Double-quoted strings.
- Organize by feature/responsibility (`Models/`, `Services/`, `Views/`), not by layering — keep related files close together.
