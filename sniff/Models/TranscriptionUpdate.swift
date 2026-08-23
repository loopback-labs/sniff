import Foundation


/// A live transcription update for one speaker's in-progress or just-finished utterance.
///
/// Streaming ASR engines revise their own output as more audio arrives, so `text` is the
/// full text of the *current* utterance rather than an appended delta — callers should
/// replace, not concatenate, on every update until `isFinal` arrives.
struct TranscriptionUpdate: Equatable {
    var text: String
    var isFinal: Bool
}
