> **Note**: This project is for education purposes only.

# Sniff

Open Source version of cluely. This is a very basic macOS app and highlights the challenges of building a app like cluely to help with questions from your screen and audio during an interview.

## Features

- **Automatic Question Detection**: Detects questions from both screen content and audio transcription (needs enhancement)
- **Multiple LLM Providers**: Supports OpenAI, Claude (Anthropic), Gemini (Google), and Perplexity
- **Real-time Transcription**: Captures and transcribes audio in real-time
- **Screen Capture**: Reads text from your screen to detect questions
- **Overlay Windows**: Displays answers in non-intrusive overlay windows
- **Manual Trigger**: Press `⌘⇧Q` to manually trigger question detection
- **Keyboard Navigation**: Navigate through Q&A history with arrow keys
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

4. Grant necessary permissions when prompted:
   - Screen Recording permission
   - Microphone permission
   - Speech Recognition permission
   - Accessibility permission (for keyboard shortcuts)

## Configuration

1. Click the Sniff icon in the menu bar
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

1. Click the Sniff icon in the menu bar
2. Click "Start" to begin capturing

### Automatic Mode

When automatic mode is enabled (default), Sniff will:
- Monitor screen content for questions
- Monitor audio transcription for questions
- Automatically send detected questions to your selected LLM provider
- Display answers in the overlay window

### Manual Mode

1. Disable "Automatic Mode" in the menu bar
2. Press `⌘⇧Q` to manually trigger question detection
3. Sniff will use the latest screen content or audio transcription

### Keyboard Shortcuts

- `⌘⇧Q`: Manually trigger question detection (global)
- `←`: Navigate to previous Q&A (when overlay is focused)
- `→`: Navigate to next Q&A (when overlay is focused)
- `⌘↑`: Jump to first Q&A (when overlay is focused)
- `⌘↓`: Jump to last Q&A (when overlay is focused)

### Overlay Windows

- **Q&A Window**: Displays detected questions and answers (top-right)
- **Transcript Window**: Shows real-time audio transcription (top-left)

You can toggle overlay visibility in screenshots via Settings.

## Architecture

```
sniff/
├── Models/          # Data models (QAItem, LLMProvider, etc.)
├── Services/        # Core services (audio capture, screen capture, LLM services)
├── Views/          # SwiftUI views
└── AppCoordinator.swift  # Main app coordinator
```

### Key Components

- **AppCoordinator**: Manages app state and coordinates services
- **ScreenCaptureService**: Captures and extracts text from screen
- **AudioCaptureService**: Captures and transcribes audio
- **QuestionDetectionService**: Detects questions in text
- **QAManager**: Manages Q&A items and navigation
- **LLM Services**: Handle communication with various LLM providers

## Privacy & Security

- API keys are stored securely in macOS Keychain
- All audio processing happens locally
- Screen capture requires explicit user permission
- No data is sent to third parties except your selected LLM provider

## Permissions

Sniff requires the following permissions:

- **Screen Recording**: To read screen content and detect questions
- **Microphone**: To capture system audio
- **Speech Recognition**: To transcribe audio into text
- **Accessibility**: To register global keyboard shortcuts

## Dependencies

- [HotKey](https://github.com/soffes/HotKey): Global keyboard shortcut handling

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with SwiftUI and Swift
- Uses macOS native APIs for screen capture and audio processing
