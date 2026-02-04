//
//  SpeechEngine.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 04/02/26.
//

import Foundation

enum SpeechEngine: String, CaseIterable, Identifiable {
    case apple
    case whisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:
            return "Apple Speech"
        case .whisper:
            return "Whisper (Local)"
        }
    }
}
