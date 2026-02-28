//
//  TranscriptBuffer.swift
//  sniff
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import Foundation
import Combine

private struct TranscriptChunk: Equatable {
    let text: String
    let timestamp: Date
    let speaker: TranscriptSpeaker
}

struct TranscriptDisplayChunk: Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    let speaker: TranscriptSpeaker
    
    init(text: String, timestamp: Date, speaker: TranscriptSpeaker) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.speaker = speaker
    }
}

@MainActor
final class TranscriptBuffer: ObservableObject {
    @Published private(set) var displayChunks: [TranscriptDisplayChunk] = []
    @Published private(set) var latestQuestion: String?

    private let maxLineLength: Int
    private let displayWindowSeconds: TimeInterval
    private let detectionWindowSeconds: TimeInterval
    private let maxDisplayCharacters: Int
    private let maxPendingCharacters: Int
    private let duplicateWindowSeconds: TimeInterval
    private let duplicateCheckCount: Int

    private var tailChunks: [TranscriptChunk] = []
    private var pendingText: String = ""
    private var sessionFileHandle: FileHandle?
    private var sessionURL: URL?
    private let isoFormatter = ISO8601DateFormatter()

    init(
        maxLineLength: Int = 60,
        displayWindowSeconds: TimeInterval = 600,
        detectionWindowSeconds: TimeInterval = 300,
        maxDisplayCharacters: Int = 8000,
        maxPendingCharacters: Int = 3000,
        duplicateWindowSeconds: TimeInterval = 5,
        duplicateCheckCount: Int = 6
    ) {
        self.maxLineLength = maxLineLength
        self.displayWindowSeconds = displayWindowSeconds
        self.detectionWindowSeconds = detectionWindowSeconds
        self.maxDisplayCharacters = maxDisplayCharacters
        self.maxPendingCharacters = maxPendingCharacters
        self.duplicateWindowSeconds = duplicateWindowSeconds
        self.duplicateCheckCount = duplicateCheckCount
    }
    
    func updateLatestQuestion(_ question: String?) {
        latestQuestion = question
    }

    func startSession(saveDirectoryURL: URL) {
        stopSession()

        do {
            try FileManager.default.createDirectory(
                at: saveDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let timestamp = formattedDateForFilename(Date())
            let randomSuffix = String(UUID().uuidString.prefix(8)).lowercased()
            let filename = "\(timestamp)-\(randomSuffix).txt"
            let fileURL = saveDirectoryURL.appendingPathComponent(filename)

            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
            sessionFileHandle = try FileHandle(forWritingTo: fileURL)
            sessionURL = fileURL
        } catch {
            sessionFileHandle = nil
            sessionURL = nil
            print("⚠️ Failed to start transcript session: \(error)")
        }
    }

    func stopSession() {
        if let handle = sessionFileHandle {
            try? handle.close()
        }
        sessionFileHandle = nil
        sessionURL = nil
    }

    func append(deltaText: String, speaker: TranscriptSpeaker, at timestamp: Date = Date()) {
        let trimmed = deltaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if pendingText.isEmpty {
            pendingText = trimmed
        } else {
            if needsSpaceBetween(pendingText, trimmed) {
                pendingText.append(" ")
            }
            pendingText.append(trimmed)
        }

        if pendingText.count > maxPendingCharacters {
            let start = pendingText.index(pendingText.endIndex, offsetBy: -maxPendingCharacters)
            pendingText = String(pendingText[start...])
        }

        let extraction = extractCompleteSentences(from: pendingText)
        pendingText = extraction.remainder

        guard !extraction.sentences.isEmpty else { return }

        for sentence in extraction.sentences {
            guard !isDuplicateRecentSentence(sentence, at: timestamp) else { continue }
            let chunk = TranscriptChunk(text: sentence, timestamp: timestamp, speaker: speaker)
            tailChunks.append(chunk)
            persist(chunk: chunk)
        }
        pruneTail(now: timestamp)
    }

    func refreshDisplay() {
        let newChunks = tailChunks.map { chunk in
            TranscriptDisplayChunk(text: chunk.text, timestamp: chunk.timestamp, speaker: chunk.speaker)
        }
        if newChunks != displayChunks {
            displayChunks = newChunks
        }
    }

    func recentTextForDetection(now: Date = Date()) -> String {
        let cutoff = now.addingTimeInterval(-detectionWindowSeconds)
        let recentChunks = tailChunks.filter { $0.timestamp >= cutoff }
        var text = joinChunks(recentChunks)
        let pending = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            if text.isEmpty {
                text = pending
            } else if needsSpaceBetween(text, pending) {
                text.append(" ")
                text.append(pending)
            } else {
                text.append(pending)
            }
        }
        return text
    }
    
    func clear() {
        displayChunks = []
        latestQuestion = nil
        tailChunks.removeAll()
        pendingText = ""
    }

    private func pruneTail(now: Date) {
        let cutoff = now.addingTimeInterval(-displayWindowSeconds)
        if let firstIndex = tailChunks.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstIndex > 0 {
                tailChunks.removeFirst(firstIndex)
            }
        } else {
            tailChunks.removeAll()
        }
    }

    private func buildTailText() -> String {
        // Show live (in-progress) speech immediately in the transcript window,
        // but only persist sentence-complete chunks to disk.
        var text = joinChunks(tailChunks)
        let pending = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            if text.isEmpty {
                text = pending
            } else if needsSpaceBetween(text, pending) {
                text.append(" ")
                text.append(pending)
            } else {
                text.append(pending)
            }
        }
        if text.count > maxDisplayCharacters {
            let start = text.index(text.endIndex, offsetBy: -maxDisplayCharacters)
            text = String(text[start...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func joinChunks(_ chunks: [TranscriptChunk]) -> String {
        var result = ""
        for chunk in chunks {
            let text = chunk.text
            if result.isEmpty {
                result = text
                continue
            }
            if needsSpaceBetween(result, text) {
                result.append(" ")
            }
            result.append(text)
        }
        return result
    }

    private func needsSpaceBetween(_ lhs: String, _ rhs: String) -> Bool {
        guard let last = lhs.last, let first = rhs.first else { return false }
        return !last.isWhitespace && !first.isWhitespace
    }

    private func wrap(text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var lines: [String] = []
        var current = ""

        for wordSub in words {
            let word = String(wordSub)
            if current.isEmpty {
                current = word
                continue
            }

            if current.count + 1 + word.count <= maxLineLength {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines
    }

    private func extractCompleteSentences(from text: String) -> (sentences: [String], remainder: String) {
        let pattern = "[.!?]+"
        var sentences: [String] = []
        var remaining = text

        while let range = remaining.range(of: pattern, options: .regularExpression) {
            let sentence = String(remaining[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            remaining = String(remaining[range.upperBound...])
        }

        let remainder = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return (sentences, remainder)
    }

    private func isDuplicateRecentSentence(_ sentence: String, at timestamp: Date) -> Bool {
        let normalized = normalize(sentence)
        guard !normalized.isEmpty else { return true }

        let recent = tailChunks.suffix(duplicateCheckCount)
        for chunk in recent {
            let timeDelta = abs(chunk.timestamp.timeIntervalSince(timestamp))
            if timeDelta <= duplicateWindowSeconds && normalize(chunk.text) == normalized {
                return true
            }
        }
        return false
    }

    private func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let components = trimmed.split(whereSeparator: { $0.isWhitespace })
        return components.joined(separator: " ")
    }

    private func persist(chunk: TranscriptChunk) {
        guard let handle = sessionFileHandle else { return }
        let line = "[\(isoFormatter.string(from: chunk.timestamp))] \(chunk.speaker.displayLabel) \(chunk.text)\n"
        guard let data = line.data(using: .utf8) else { return }
        handle.write(data)
    }

    private func formattedDateForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
