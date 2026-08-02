import Foundation
import FluidAudio

/// Streaming Parakeet EOU 120M chunk-size tiers. Only the EOU family is offered here — see the
/// streaming-ASR plan for why EOU (built-in end-of-utterance detection) was chosen over the
/// Nemotron streaming family (no boundary callback, ~2s+ latency) for this app's live-overlay use case.
enum ParakeetModelChoice: String, CaseIterable, Identifiable {
    case eou160ms
    case eou320ms
    case eou1280ms

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eou160ms:
            return "Fastest (160ms)"
        case .eou320ms:
            return "Balanced (320ms)"
        case .eou1280ms:
            return "Most accurate (1280ms)"
        }
    }

    var streamingChunkSize: StreamingChunkSize {
        switch self {
        case .eou160ms:
            return .ms160
        case .eou320ms:
            return .ms320
        case .eou1280ms:
            return .ms1280
        }
    }
}

