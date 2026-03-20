import Foundation
import FluidAudio

enum ParakeetModelChoice: String, CaseIterable, Identifiable {
    case v2English
    case v3Multilingual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v2English:
            return "v2 (English)"
        case .v3Multilingual:
            return "v3 (Multilingual)"
        }
    }

    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v2English:
            return .v2
        case .v3Multilingual:
            return .v3
        }
    }
}

