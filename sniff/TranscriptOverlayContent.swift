import SwiftUI

struct TranscriptOverlayContentView: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer

    var body: some View {
        StyledOverlayView(
            config: .transcript,
            icon: "waveform",
            iconColor: .green
        ) {
            VStack(spacing: 6) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if transcriptBuffer.displayChunks.isEmpty {
                                VStack(spacing: 6) {
                                    Image(systemName: "waveform.badge.mic")
                                        .font(.title3)
                                        .foregroundStyle(.tertiary)
                                    Text("Listening…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
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
        return chunk.text.localizedCaseInsensitiveContains(question)
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
    buffer.append(deltaText: "What is the best way to test a whisper model?", speaker: .you)
    buffer.append(deltaText: "It should stream quickly and be accurate.", speaker: .others)
    buffer.updateLatestQuestion("What is the best way to test a whisper model?")
    buffer.refreshDisplay()
    return TranscriptOverlayContentView(transcriptBuffer: buffer)
        .frame(width: 360, height: 220)
        .padding()
}
