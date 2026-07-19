---
root: true
targets:
  - '*'
globs:
  - '**/*'
---
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Sniff is a macOS menu bar app (SwiftUI/AppKit) that captures screen + audio during calls/interviews and streams LLM-generated answers into draggable overlay windows. See `README.md` for the full feature/permissions/usage rundown — don't duplicate it here.

## Commands

Build and run via Xcode (`open sniff.xcodeproj`, scheme **sniff**, ⌘R) — this is the primary workflow for UI/behavior changes since the app needs real screen/mic/system-audio permissions.

Command line:
```bash
# Build (Debug)
xcodebuild -project sniff.xcodeproj -scheme sniff -configuration Debug build

# Run all tests (Testing framework, not XCTest)
xcodebuild test -project sniff.xcodeproj -scheme sniff -destination 'platform=macOS'

# Run a single test
xcodebuild test -project sniff.xcodeproj -scheme sniff -destination 'platform=macOS' \
  -only-testing:sniffTests/sniffTests/promptBuilderUsesEmptyTranscriptFallback

# Release build + install to /Applications
./build-and-install.sh
```

Tests live in a single file, `sniffTests/sniffTests.swift`, using Swift Testing (`@Test`/`#expect`, not XCTest) and `@testable import Sniff` (note capital S — the module name, distinct from the `sniff` target/scheme). There is no CI test job; `.github/workflows/release.yml` only builds and packages a DMG on manual dispatch.

SPM dependencies (resolved into the Xcode project, no `Package.swift` at the root): `HotKey` (global shortcuts), `FluidAudio` (Parakeet on-device transcription), `argmax-oss-swift` (WhisperKit), `textual` (Markdown rendering), `swiftui-math`.

## Architecture

`AppCoordinator` (`sniff/AppCoordinator.swift`) is the app's single orchestrator — a `@MainActor` `ObservableObject` owning every service, both overlay windows, hotkeys, and the `@Published` settings that drive UI. Almost everything routes through it; read it first when tracing a feature end to end.

### Prompting pipeline (the core flow)

1. **Capture** — `ScreenCaptureService` (screenshots + system audio) and the selected speech engine (`LocalWhisperService` or `ParakeetTranscriptionService`) publish live transcript text via Combine (`$micTranscribedText` / `$systemTranscribedText`).
2. **Delta extraction** — `AppCoordinator` runs each new publish through a per-source `TranscriptionDeltaProcessor` (one instance per engine × speaker) to get only the newly-added suffix, then appends it to `TranscriptBuffer` with a `TranscriptSpeaker` (`.you` / `.others`) label.
3. **Question detection** — on a 1s debounce, `AudioQuestionPipeline` (wrapping `QuestionDetectionService`) scans `TranscriptBuffer.recentTextForDetection()` for question-like sentences and updates `TranscriptBuffer.latestQuestion` for transcript-view highlighting.
4. **Trigger** — a hotkey, menu action, or typed message calls `AppCoordinator.runMode(_:)` with a `PromptMode` (`answerQuestion`, `solveScreen`, `sayNext`, `followUps`, `recap`, `ask`). This is the single entry point for every prompting flow.
5. **Prompt assembly** — `PromptBuilder` turns the mode + `TranscriptBuffer` + recent `QAItem` history into a `PromptPayload` (system prompt, user message, `LLMRequestOptions`). Per-mode behavior — transcript char budget, whether Q&A history is included, whether a screenshot is required/optional, token limits/temperature — is all declared as properties on `PromptMode` itself (`sniff/Models/PromptMode.swift`); add new modes there rather than branching in `AppCoordinator`.
6. **LLM call** — `LLMServiceFactory` picks a concrete `LLMService` (`OpenAIService`, `ClaudeService`, `GeminiService`, `ChatGPTService`) based on `selectedProvider`, reading API keys from `KeychainService` (or the OAuth session from `ChatGPTAuthManager` for ChatGPT). All non-ChatGPT services subclass `BaseLLMService`, which implements the shared SSE streaming loop (`performStreamRequest`) — subclasses only need to override request-body building and stream-line parsing.
7. **Streaming to UI** — chunks flow back through an `onChunk` closure into `QAManager`, which owns the `QAItem` list the Q&A overlay renders and supports history navigation (⌥←/→/↑/↓).

### Overlays

`OverlayWindow` (`sniff/Views/OverlayWindow.swift`) is a borderless, click-through-until-hovered `NSWindow`; `WindowConfiguration` (`sniff/Models/WindowConfiguration.swift`) declares fixed placement/size for the two overlays (Q&A top-right, transcript top-left). `AppCoordinator.startClickThroughTracking()` polls the cursor at ~20Hz (no Accessibility permission needed) to flip each window's click-through state — mid-drag/resize gestures are protected from having the flag flip under them.

### Speech engines

Two on-device engines are swappable at runtime via `selectedSpeechEngine`: `LocalWhisperService` (WhisperKit) and `ParakeetTranscriptionService` (FluidAudio). `AppCoordinator.speechRouting(for:)` is the one place that maps an engine to its publishers, capture start closure, and delta processors — extend it there when adding a new engine rather than scattering `switch selectedSpeechEngine` elsewhere.

## Conventions

- SwiftUI for all new UI code.
- 2-space indentation, double-quoted strings.
- Organize by feature/responsibility (`Models/`, `Services/`, `Views/`), not by layering — keep related files close together.
