//
//  TranscriptOverlayView.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import SwiftUI

struct TranscriptOverlayView: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.green)
                Text("Transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            ScrollView {
                Text(transcriptBuffer.displayText.isEmpty ? "Listening..." : transcriptBuffer.displayText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 140)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
    }
}
