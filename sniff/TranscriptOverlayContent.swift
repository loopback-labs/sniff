import SwiftUI

struct TranscriptOverlayContentView: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer

    var body: some View {
        StyledOverlayView(
            config: .transcript,
            icon: "waveform",
            iconColor: .green
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if transcriptBuffer.displayChunks.isEmpty {
                            Text("Listening...")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            ForEach(transcriptBuffer.displayChunks) { chunk in
                                ChatBubbleView(
                                    chunk: chunk,
                                    isHighlighted: isChunkHighlighted(chunk)
                                )
                                .id(chunk.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 140)
                .onChange(of: transcriptBuffer.displayChunks.count) { _, _ in
                    if let lastChunk = transcriptBuffer.displayChunks.last {
                        withAnimation {
                            proxy.scrollTo(lastChunk.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func isChunkHighlighted(_ chunk: TranscriptDisplayChunk) -> Bool {
        guard let question = transcriptBuffer.latestQuestion else { return false }
        return chunk.text.localizedCaseInsensitiveContains(question)
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
        switch chunk.speaker {
        case .you:
            return Color.green.opacity(0.2)
        case .others:
            return Color.blue.opacity(0.15)
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
