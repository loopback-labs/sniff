import SwiftUI

struct TranscriptOverlayContentView: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        StyledOverlayView(
            config: .transcript,
            icon: "waveform",
            iconColor: .green
        ) {
            VStack(spacing: 6) {
                if coordinator.systemAudioUnavailable {
                    CaptureWarningView(
                        title: "Only your microphone is being transcribed",
                        detail: coordinator.systemAudioFailureReason
                            ?? "System audio capture is unavailable."
                    )
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if transcriptBuffer.displayChunks.isEmpty {
                                ListeningPlaceholderView(micLevel: coordinator.micLevel)
                            } else {
                                ForEach(transcriptBuffer.displayChunks) { chunk in
                                    ChatBubbleView(
                                        chunk: chunk,
                                        isHighlighted: isChunkHighlighted(chunk)
                                    )
                                    .opacity(chunk.isPending ? 0.6 : 1.0)
                                    .id(chunk.id)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 140)
                    .onChange(of: transcriptBuffer.displayChunks) { _, _ in
                        if let lastChunk = transcriptBuffer.displayChunks.last {
                            withAnimation {
                                proxy.scrollTo(lastChunk.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                ShortcutsFooterView()
            }
        }
    }

    private func isChunkHighlighted(_ chunk: TranscriptDisplayChunk) -> Bool {
        guard let question = transcriptBuffer.latestQuestion else { return false }
        // Only highlight a chunk that is essentially *just* the question. The detected question is
        // often most of the recent transcript, so a bare `contains` painted whole bubbles yellow.
        guard chunk.text.localizedCaseInsensitiveContains(question) else { return false }
        return Double(question.count) >= Double(chunk.text.count) * 0.6
    }
}

/// Inline warning strip for degraded-capture states that would otherwise be invisible.
private struct CaptureWarningView: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }
}

/// Empty-transcript state. Shows a live input meter so "capturing but hearing nothing" (muted mic,
/// wrong input device) is visibly different from "capturing and waiting for speech".
private struct ListeningPlaceholderView: View {
    let micLevel: Float

    /// Don't accuse the mic of being dead before audio has had a chance to arrive — the first
    /// buffers land a beat after capture starts.
    @State private var graceElapsed = false

    private var isSilent: Bool { graceElapsed && micLevel < AudioLevelMeter.silenceThreshold }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isSilent ? "mic.slash" : "waveform.badge.mic")
                .font(.title3)
                .foregroundStyle(isSilent ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))

            Text(isSilent ? "No microphone input detected" : "Listening…")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: Double(min(max(micLevel * 3, 0), 1)))
                .progressViewStyle(.linear)
                .tint(isSilent ? .secondary : .green)
                .frame(width: 120)

            if isSilent {
                Text("Check the input device in Settings › Speech.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .animation(.easeOut(duration: 0.2), value: isSilent)
        .task {
            try? await Task.sleep(for: .seconds(4))
            graceElapsed = true
        }
    }
}

private struct ShortcutsFooterView: View {
    private static let shortcuts: [(keys: String, label: String)] = [
        ("⌘⇧A", "Answer"),
        ("⌘⇧Q", "Solve screen"),
        ("⌘⇧S", "Say next"),
        ("⌘⇧F", "Follow-ups"),
        ("⌘⇧E", "Recap"),
        ("⌘⇧K", "Ask"),
        ("⌘⇧I", "Click-through"),
    ]

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
            spacing: 4
        ) {
            ForEach(Self.shortcuts, id: \.keys) { shortcut in
                HStack(spacing: 4) {
                    Text(shortcut.keys)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    Text(shortcut.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct ChatBubbleView: View {
    let chunk: TranscriptDisplayChunk
    let isHighlighted: Bool

    var body: some View {
        HStack {
            if chunk.speaker == .you {
                Spacer()
            }

            Text(chunk.text)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(backgroundColor)
                .foregroundColor(textColor)
                .cornerRadius(12)
                .textSelection(.enabled)
                .frame(maxWidth: 280, alignment: alignment)

            if chunk.speaker == .others {
                Spacer()
            }
        }
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return Color.yellow.opacity(0.7)
        }
        // Slightly stronger fills so bubbles stay legible over the blurred material backdrop.
        switch chunk.speaker {
        case .you:
            return Color.green.opacity(0.28)
        case .others:
            return Color.blue.opacity(0.22)
        }
    }

    private var textColor: Color {
        if isHighlighted {
            return .black
        }
        return .primary
    }

    private var alignment: Alignment {
        switch chunk.speaker {
        case .you:
            return .trailing
        case .others:
            return .leading
        }
    }
}

#Preview("Transcript Overlay") {
    let buffer = TranscriptBuffer()
    buffer.commitPending(text: "What is the best way to test a whisper model?", speaker: .you)
    buffer.commitPending(text: "It should stream quickly and be accurate.", speaker: .others)
    buffer.updateLatestQuestion("What is the best way to test a whisper model?")
    return TranscriptOverlayContentView(transcriptBuffer: buffer)
        .environmentObject(AppCoordinator())
        .frame(width: 360, height: 220)
        .padding()
}
