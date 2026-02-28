//
//  TranscriptSpeaker.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation

enum TranscriptSpeaker: CaseIterable {
    case you
    case others

    var displayLabel: String {
        switch self {
        case .you:
            return "[You]"
        case .others:
            return "[Others]"
        }
    }
}
