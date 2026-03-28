> **Note**: This project is for education purposes only.

# Sniff

Open-source macOS menu bar app in the spirit of tools like Cluely: it captures screen and audio context to help answer questions during calls or interviews. The build is intentionally small so you can see what goes into this kind of product (permissions, capture pipelines, LLM wiring, overlays).

**User-facing name:** **SystemUISyncAgent** in Activity Monitor and Login Items (the shipped bundle is `syncsd.app`).

## Features

- **Question detection** in live transcription (highlighted in the transcript; use **⌘⇧A** to send to the LLM)
- **LLM providers:** OpenAI, Claude (Anthropic), Gemini (Google), and **ChatGPT** (session-based sign-in, not a stored API key)
- **Per-provider model picker**, with a clear path to vision-capable models for screen questions
- **Speech engines (on-device transcription):**
  - **Whisper** — WhisperKit for microphone and system audio, with on-demand model downloads
  - **Parakeet** — FluidAudio Parakeet for microphone and system audio
- **Dual-source transcript** — live mic + system audio with speaker labels (`[You]` / `[Others]`)
- **Screen question capture** — screenshot sent to the selected provider when the model supports images
- **Overlays** — draggable, resizable, click-through Q&A and transcript windows until hovered
- **Manual triggers** — global hotkeys for screen/audio questions and capture on/off
- **Q&A history** — navigate entries when the Q&A overlay is the key window
- **Markdown answers** — rendered for readability (Textual)
- **Secure storage** — API keys for OpenAI, Claude, and Gemini in the macOS Keychain; ChatGPT uses OAuth/session handling in-app
- **Settings** — input device selection, optional inclusion of overlays in screenshots

## Requirements

- macOS 26.0 (Tahoe) or later (`LSMinimumSystemVersion` in the app)
- Xcode 26.x recommended (project `MACOSX_DEPLOYMENT_TARGET` is 26.0+)
- Swift 5 (as set in the Xcode project)

## Installation

### Building from source

1. Clone the repository:

```bash
git clone https://github.com/loopback-labs/sniff.git
cd sniff
```

2. Open the project in Xcode:

```bash
open sniff.xcodeproj
```

3. Build and run the **sniff** scheme (⌘R).

Install to `/Applications` with the release script:

```bash
./build-and-install.sh
```

This builds `syncsd.app` (display name: SystemUISyncAgent).

4. Grant permissions when prompted:

   - Screen Recording
   - Microphone
   - Automation / related prompts for global shortcuts (see `Info.plist` usage strings)
   - Speech Recognition string is present in `Info.plist`; primary transcription paths use on-device Whisper or Parakeet

## GitHub releases

Maintainers: in **Actions**, run workflow **Release macOS DMG** with branch **main** selected, enter a version (for example `1.0.1`), and the job uploads `Sniff-<version>.dmg` to a new release tagged `v<version>`.

## Configuration

1. Click the **SystemUISyncAgent** icon in the menu bar  
2. Choose **Settings…**  
3. Pick an **LLM provider** and **model** (use a vision-capable model if you rely on screen questions)  
4. **API keys:** enter and save for OpenAI, Claude, or Gemini. For **ChatGPT**, use the in-settings sign-in flow (OAuth).  
5. Choose **Speech Engine** (Whisper or Parakeet) and configure Whisper model download / Parakeet options as shown  
6. Optionally set **Input Device** and **Include Overlay in Screenshots**

### Supported providers

| Provider   | Auth / credential        |
|-----------|----------------------------|
| OpenAI    | API key (Keychain)         |
| Claude    | API key (Keychain)         |
| Gemini    | API key (Keychain)         |
| ChatGPT   | Sign in (session in app)   |

## Usage

### Starting the app

1. Open from the menu bar  
2. **Start** capture (or **⌘⇧W**)

### Questions and hotkeys

1. **⌘⇧Q** — screen question (uses current screenshot)  
2. **⌘⇧A** — audio question (uses latest detected question from transcription, or falls back to detecting a question in recent text)

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘⇧W | Start / stop capture |
| ⌘⇧Q | Screen question |
| ⌘⇧A | Audio question |
| ⌘⇧R | Quit (stops capture then terminates) |
| ⌥← / ⌥→ | Previous / next Q&A *(Q&A overlay must be key window)* |
| ⌥↑ / ⌥↓ | First / last Q&A *(Q&A overlay must be key window)* |

### Overlay windows

- **Q&A** — questions and streamed answers (default placement: top-right area)  
- **Transcript** — live transcription with labels and question highlighting (top-left area)  
- **Interaction** — click-through until you hover; then drag and resize  

## Architecture (high level)

```text
sniff/
├── Models/                 # LLMProvider, SpeechEngine, QAItem, catalogs, window config, etc.
├── Services/               # Capture, transcription (WhisperKit / Parakeet), LLM clients, Q&A, keychain
├── Views/                  # SwiftUI: settings, overlays, Q&A display, transcript UI
├── AppCoordinator.swift    # Orchestrates capture, hotkeys, providers, overlays
├── sniffApp.swift          # App entry, menu bar content
└── TranscriptOverlayContent.swift
```

## Privacy and security

- OpenAI, Claude, and Gemini API keys are stored in the **Keychain** on this Mac.  
- **ChatGPT** uses an authenticated session managed in the app (not a pasted API key in Keychain for that provider).  
- **Transcription** for Whisper and Parakeet is designed to run **on-device**; **answers** still go to the cloud provider you select.  
- Screen capture only runs with OS screen-recording consent.  
- Review each provider’s terms before sending real meeting or interview content.

## Permissions

The app declares usage descriptions for screen capture, microphone, speech recognition (see `Info.plist`), and automation-related access for global shortcuts. Grant what macOS prompts for when you first use capture and hotkeys.

## Contributing

Contributions are welcome. Please open a pull request.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file.
