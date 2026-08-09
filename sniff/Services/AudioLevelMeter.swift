import Foundation


/// Smoothed peak meter shared by both speech engines.
///
/// Exists so the UI can distinguish "capturing but hearing nothing" (muted or wrong input device)
/// from "capturing and waiting for you to speak" — previously both looked identical.
enum AudioLevelMeter {
  /// Fast attack, slow decay: jumps straight to a new peak so speech registers immediately, then
  /// eases back down so brief gaps between words don't make the meter flicker to zero.
  static func next(level: Float, samples: [Float], decay: Float = 0.85) -> Float {
    var peak: Float = 0
    for sample in samples {
      let magnitude = abs(sample)
      if magnitude > peak { peak = magnitude }
    }
    return peak > level ? min(peak, 1) : level * decay
  }

  /// Peak below which the input is treated as silence for "no audio detected" messaging.
  static let silenceThreshold: Float = 0.01
}
