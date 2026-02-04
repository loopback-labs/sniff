import SwiftUI

struct TranscriptOverlayContentView: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer

    var body: some View {
        StyledOverlayView(
            config: .transcript,
            icon: "waveform",
            iconColor: .green
        ) {
            ScrollView {
                transcriptText
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 140)
        }
    }

    @ViewBuilder
    private var transcriptText: some View {
        let fullText = transcriptBuffer.displayText
        if fullText.isEmpty {
            Text("Listening...")
        } else if let question = transcriptBuffer.latestQuestion,
                  let range = findQuestionRange(in: fullText, question: question) {
            buildHighlightedText(fullText: fullText, highlightRange: range)
        } else {
            Text(fullText)
        }
    }

    private func findQuestionRange(in text: String, question: String) -> Range<String.Index>? {
        if let range = text.range(of: question, options: [.caseInsensitive, .diacriticInsensitive]) {
            return range
        }

        // Replace (not remove) whitespace characters to keep string length stable for index mapping.
        let normalizedText = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedRange = normalizedText.range(
            of: normalizedQuestion,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            return nil
        }

        let startOffset = normalizedText.distance(from: normalizedText.startIndex, to: normalizedRange.lowerBound)
        let endOffset = normalizedText.distance(from: normalizedText.startIndex, to: normalizedRange.upperBound)

        guard let startIndex = text.index(text.startIndex, offsetBy: startOffset, limitedBy: text.endIndex),
              let endIndex = text.index(text.startIndex, offsetBy: endOffset, limitedBy: text.endIndex),
              startIndex <= endIndex else {
            return nil
        }

        return startIndex..<endIndex
    }

    private func buildHighlightedText(fullText: String, highlightRange: Range<String.Index>) -> Text {
        var attributedString = AttributedString(fullText)
        if let attrRange = Range(highlightRange, in: attributedString) {
            attributedString[attrRange].foregroundColor = .black
            attributedString[attrRange].backgroundColor = .yellow.opacity(0.7)
        }
        return Text(attributedString)
    }
}
