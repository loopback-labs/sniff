//
//  TranscriptOverlayView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

// Wrapper that applies config-based styling
struct TranscriptOverlayContent: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer
    
    var body: some View {
        StyledOverlayView(
            config: .transcript,
            icon: "waveform",
            iconColor: .green,
            headerTrailing: questionDetectedBadge
        ) {
            TranscriptTextView(transcriptBuffer: transcriptBuffer)
        }
    }
    
    private var questionDetectedBadge: AnyView? {
        guard transcriptBuffer.latestQuestion != nil else { return nil }
        return AnyView(
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Question detected")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            .transition(.opacity.combined(with: .scale))
            .animation(.easeInOut(duration: 0.2), value: transcriptBuffer.latestQuestion != nil)
        )
    }
}

// Pure content view - just the transcript text
struct TranscriptTextView: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer
    
    var body: some View {
        ScrollView {
            highlightedText
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 140)
    }
    
    @ViewBuilder
    private var highlightedText: some View {
        if transcriptBuffer.displayText.isEmpty {
            Text("Listening...")
        } else if let question = transcriptBuffer.latestQuestion,
                  let range = findQuestionRange(in: transcriptBuffer.displayText, question: question) {
            buildHighlightedText(fullText: transcriptBuffer.displayText, highlightRange: range)
        } else {
            Text(transcriptBuffer.displayText)
        }
    }
    
    private func findQuestionRange(in text: String, question: String) -> Range<String.Index>? {
        if let range = text.range(of: question, options: [.caseInsensitive, .diacriticInsensitive]) {
            return range
        }
        
        let textWithoutNewlines = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        
        let questionTrimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let normalizedRange = textWithoutNewlines.range(of: questionTrimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            let normalizedStart = textWithoutNewlines.distance(from: textWithoutNewlines.startIndex, to: normalizedRange.lowerBound)
            let normalizedEnd = textWithoutNewlines.distance(from: textWithoutNewlines.startIndex, to: normalizedRange.upperBound)
            
            var charCount = 0
            var startPos: String.Index?
            var endPos: String.Index?
            
            var currentIndex = text.startIndex
            while currentIndex < text.endIndex {
                if charCount == normalizedStart && startPos == nil {
                    startPos = currentIndex
                }
                if charCount == normalizedEnd && endPos == nil {
                    endPos = currentIndex
                    break
                }
                
                charCount += 1
                currentIndex = text.index(after: currentIndex)
            }
            
            if endPos == nil && charCount == normalizedEnd {
                endPos = text.endIndex
            }
            
            if let start = startPos, let end = endPos {
                return start..<end
            }
        }
        
        return nil
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
