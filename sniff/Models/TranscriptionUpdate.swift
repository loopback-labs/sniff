//
//  TranscriptionUpdate.swift
//  sniff
//

import Foundation

/// A live transcription update for one speaker's in-progress or just-finished utterance.
///
/// Streaming ASR engines revise their own output as more audio arrives, so `text` is the
/// full text of the *current* utterance rather than an appended delta — callers should
/// replace, not concatenate, on every update until `isFinal` arrives.
struct TranscriptionUpdate: Equatable {
    /// Full text of the current utterance. May be revised across successive updates
    /// while `isFinal` is false.
    var text: String
    /// True once the engine has committed this utterance (e.g. end-of-utterance detected).
    var isFinal: Bool
}
