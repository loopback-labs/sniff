import Foundation


enum TranscriptSpeaker: CaseIterable, Hashable, Sendable {
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
