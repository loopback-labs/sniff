> **Note**: This project is for education purposes only.

# Sniff

Open Source version of cluely. This is a very basic macOS app and highlights the challenges of building a app like cluely to help with questions from your screen and audio during an interview.

user-facing name: **SystemUISyncAgent** in Activity Monitor / Login Items

## Features

- **Automatic Question Detection**: Detects questions from live audio
- **Multiple LLM Providers**: Supports OpenAI, Claude (Anthropic), Gemini (Google), and Perplexity
- **Real-time Dual-Source Transcription**: Live transcript from microphone + system audio with speaker labels (`[You]` / `[Others]`)
- **Screen Question Capture**: Sends a screenshot to the selected provider for visual Q&A
- **Overlay Windows**: Draggable, resizable, click-through overlays for Q&A and transcript
- **Manual Triggers**: Dedicated hotkeys for screen and audio questions
- **Keyboard Navigation**: Navigate through Q&A history with arrow keys
- **Markdown Answers**: Renders structured answers for readability
- **Secure API Key Storage**: API keys are stored securely in macOS Keychain

## Requirements

- macOS 26.0 (Tahoe) or later
- Xcode 26.0 or later
- Swift 6.0 or later

## Installation

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/yourusername/sniff.git
cd sniff
```

2. Open the project in Xcode:
```bash
open sniff.xcodeproj
```

3. Build and run the project (⌘R)

You can also install to `/Applications` using the build script:
```bash
./build-and-install.sh
```
This produces `syncsd.app` (display name: SystemUISyncAgent).

4. Grant necessary permissions when prompted:
   - Screen Recording permission
   - Microphone permission
   - Speech Recognition permission
   - Accessibility permission (for keyboard shortcuts)

## Configuration

1. Click the SystemUISyncAgent icon in the menu bar
2. Click "Settings..."
3. Select your preferred LLM provider
4. Enter your API key for the selected provider
5. Click "Save"

### Supported Providers

- **OpenAI**: Requires an OpenAI API key
- **Claude (Anthropic)**: Requires an Anthropic API key
- **Gemini (Google)**: Requires a Google AI API key
- **Perplexity**: Requires a Perplexity API key

## Usage

### Starting the App

1. Click the SystemUISyncAgent icon in the menu bar
2. Click "Start" to begin capturing (or press `⌘⇧W`)

### Automatic Mode

When automatic mode is enabled, the app will:
- Monitor audio transcription for questions
- Optionally process screen captures for questions
- Automatically send detected questions to your selected LLM provider
- Display answers in the overlay window

### Manual Mode

1. Disable "Automatic Mode" in the menu bar
2. Press `⌘⇧Q` for a screen question or `⌘⇧A` for an audio question
3. The app will use the latest screenshot or detected audio question

### Keyboard Shortcuts

- `⌘⇧W`: Start/stop capture (global)
- `⌘⇧Q`: Screen question (global)
- `⌘⇧A`: Audio question (global)
- `←`: Navigate to previous Q&A (when overlay is focused)
- `→`: Navigate to next Q&A (when overlay is focused)
- `⌘↑`: Jump to first Q&A (when overlay is focused)
- `⌘↓`: Jump to last Q&A (when overlay is focused)

### Overlay Windows

- **Q&A Window**: Displays detected questions and answers (top-right)
- **Transcript Window**: Shows real-time mic + system transcription with source labels and question highlighting (top-left)
- **Interaction**: Windows are click-through until hovered, then draggable/resizable

You can toggle overlay visibility in screenshots via Settings.

## Architecture

```
sniff/
├── Models/          # Data models (QAItem, LLMProvider, etc.)
├── Services/        # Core services (audio capture, screen capture, LLM services)
├── Views/          # SwiftUI views
└── AppCoordinator.swift  # Main app coordinator
```

## Privacy & Security

- API keys are stored securely in macOS Keychain
- All audio processing happens locally
- Screen capture requires explicit user permission
- No data is sent to third parties except your selected LLM provider

## Permissions

The app requires the following permissions:

- **Screen Recording**: To read screen content and detect questions
- **Microphone**: To capture your voice audio
- **Speech Recognition**: To transcribe audio into text
- **Accessibility**: To register global keyboard shortcuts

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
