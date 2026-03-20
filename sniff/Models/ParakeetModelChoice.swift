import Foundation

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
}

