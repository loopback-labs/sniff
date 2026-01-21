//
//  TranscriptUpdateService.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

@MainActor
class TranscriptUpdateService {
    private let transcriptBuffer: TranscriptBuffer
    
    init(transcriptBuffer: TranscriptBuffer) {
        self.transcriptBuffer = transcriptBuffer
    }
    
    func updateDisplay(with text: String) {
        transcriptBuffer.update(with: text)
    }
    
    func updateLatestQuestion(_ question: String?) {
        transcriptBuffer.updateLatestQuestion(question)
    }
}
