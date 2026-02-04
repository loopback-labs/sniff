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
        TranscriptOverlayContentView(transcriptBuffer: transcriptBuffer)
    }
}

#Preview("Transcript Overlay") {
    let buffer = TranscriptBuffer()
    buffer.append(deltaText: "What is the best way to test a whisper model?")
    buffer.append(deltaText: "It should stream quickly and be accurate.")
    buffer.updateLatestQuestion("What is the best way to test a whisper model?")
    buffer.refreshDisplay()
    return TranscriptOverlayView(transcriptBuffer: buffer)
        .frame(width: 360, height: 220)
        .padding()
}
