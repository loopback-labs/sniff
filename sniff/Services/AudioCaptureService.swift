import Foundation

import Combine

@MainActor
final class AudioCaptureService: ObservableObject {
    @Published var micTranscribedText: String = ""
    @Published var systemTranscribedText: String = ""
    @Published var isCapturing: Bool = false

    func startCapture() throws {}

    func stopCapture() {
        isCapturing = false
    }

    func reset() {
        micTranscribedText = ""
        systemTranscribedText = ""
    }
}
