//
//  SpeechEngine.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 04/02/26.
//

import Foundation

enum SpeechEngine: String, CaseIterable, Identifiable {
    case whisper
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:
            return "Whisper"
        case .parakeet:
            return "Parakeet"
        }
    }
}
