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
    let isPending: Bool

    init(text: String, timestamp: Date, speaker: TranscriptSpeaker, id: UUID = UUID(), isPending: Bool = false) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.speaker = speaker
        self.isPending = isPending
    }

    static func == (lhs: TranscriptDisplayChunk, rhs: TranscriptDisplayChunk) -> Bool {
        lhs.text == rhs.text && lhs.speaker == rhs.speaker && lhs.isPending == rhs.isPending
    }
}

@MainActor
final class TranscriptBuffer: ObservableObject {
    @Published private(set) var displayChunks: [TranscriptDisplayChunk] = []
    @Published private(set) var latestQuestion: String?

    private let displayWindowSeconds: TimeInterval
    private let detectionWindowSeconds: TimeInterval
    private let maxPendingCharacters: Int
    private let duplicateWindowSeconds: TimeInterval
    private let duplicateCheckCount: Int

    private var tailChunks: [TranscriptChunk] = []
    private var chunkIDs: [UUID] = []
    private var pendingBySpeaker: [TranscriptSpeaker: String] = [:]
    private var pendingChunkIDs: [TranscriptSpeaker: UUID] = [:]
    private var sessionFileHandle: FileHandle?
    private var sessionURL: URL?
    private let isoFormatter = ISO8601DateFormatter()

    init(
        displayWindowSeconds: TimeInterval = 600,
        detectionWindowSeconds: TimeInterval = 300,
        maxPendingCharacters: Int = 3000,
        duplicateWindowSeconds: TimeInterval = 5,
        duplicateCheckCount: Int = 6
    ) {
        self.displayWindowSeconds = displayWindowSeconds
        self.detectionWindowSeconds = detectionWindowSeconds
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

    /// Overwrites `speaker`'s in-progress utterance. Streaming ASR revises its own output as
    /// more audio arrives, so `text` is the full text of the current utterance, not a delta —
    /// nothing here is persisted or sentence-extracted until `commitPending` finalizes it.
    func updatePending(text: String, speaker: TranscriptSpeaker) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maxPendingCharacters {
            let start = trimmed.index(trimmed.endIndex, offsetBy: -maxPendingCharacters)
            trimmed = String(trimmed[start...])
        }

        if trimmed.isEmpty {
            pendingBySpeaker.removeValue(forKey: speaker)
        } else {
            pendingBySpeaker[speaker] = trimmed
            if pendingChunkIDs[speaker] == nil {
                pendingChunkIDs[speaker] = UUID()
            }
        }
        refreshDisplay()
    }

    /// A trailing remainder is committed as its own chunk: no further revision will arrive for it.
    func commitPending(text: String, speaker: TranscriptSpeaker, at timestamp: Date = Date()) {
        defer {
            pendingBySpeaker.removeValue(forKey: speaker)
            pruneTail(now: timestamp)
            refreshDisplay()
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let extraction = extractCompleteSentences(from: trimmed)
        var sentences = extraction.sentences
        if !extraction.remainder.isEmpty {
            sentences.append(extraction.remainder)
        }

        for sentence in sentences {
            guard !isDuplicateRecentSentence(sentence, at: timestamp) else { continue }
            let chunk = TranscriptChunk(text: sentence, timestamp: timestamp, speaker: speaker)
            tailChunks.append(chunk)
            persist(chunk: chunk)
        }
    }

    func refreshDisplay() {
        while chunkIDs.count < tailChunks.count {
            chunkIDs.append(UUID())
        }

        var newChunks = zip(tailChunks, chunkIDs).map { chunk, id in
            TranscriptDisplayChunk(text: chunk.text, timestamp: chunk.timestamp, speaker: chunk.speaker, id: id)
        }
        for speaker in TranscriptSpeaker.allCases {
            guard let pending = pendingBySpeaker[speaker], !pending.isEmpty else { continue }
            let id = pendingChunkIDs[speaker] ?? UUID()
            pendingChunkIDs[speaker] = id
            newChunks.append(
                TranscriptDisplayChunk(text: pending, timestamp: Date(), speaker: speaker, id: id, isPending: true)
            )
        }
        if newChunks != displayChunks {
            displayChunks = newChunks
        }
    }

    func recentTextForDetection(now: Date = Date()) -> String {
        let cutoff = now.addingTimeInterval(-detectionWindowSeconds)
        let recentChunks = tailChunks.filter { $0.timestamp >= cutoff }
        var text = joinChunks(recentChunks)
        for speaker in TranscriptSpeaker.allCases {
            guard let pending = pendingBySpeaker[speaker], !pending.isEmpty else { continue }
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
        chunkIDs.removeAll()
        pendingBySpeaker.removeAll()
        pendingChunkIDs.removeAll()
    }

    /// Completed chunks (already pruned to `displayWindowSeconds`) plus each speaker's pending
    /// in-progress utterance (in `TranscriptSpeaker.allCases` order), oldest-committed-first.
    func recentTurns() -> [(speaker: TranscriptSpeaker, text: String)] {
        var turns = tailChunks.map { (speaker: $0.speaker, text: $0.text) }
        for speaker in TranscriptSpeaker.allCases {
            guard let pending = pendingBySpeaker[speaker], !pending.isEmpty else { continue }
            turns.append((speaker: speaker, text: pending))
        }
        return turns
    }

    func fullSessionTranscript(maxCharacters: Int) -> String? {
        guard let sessionURL, let raw = readTail(of: sessionURL, approximateCharacterBudget: maxCharacters) else {
            return nil
        }

        let lines = raw.split(separator: "\n").compactMap { line -> String? in
            formatPersistedLine(String(line))
        }
        guard !lines.isEmpty else { return nil }

        return TranscriptionTextUtils.joinTailWithinBudget(lines, charBudget: maxCharacters)
    }

    /// Reads only the tail of `url` needed to cover `approximateCharacterBudget`, instead of loading
    /// the whole (ever-growing) session file on every call. A generous byte multiplier accounts for
    /// multi-byte UTF-8; any partial leading line from the seek point is dropped.
    private func readTail(of url: URL, approximateCharacterBudget: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }

        let byteBudget = UInt64(approximateCharacterBudget) * 4
        let start = fileSize > byteBudget ? fileSize - byteBudget : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }

        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    private func formatPersistedLine(_ line: String) -> String? {
        guard let closingBracket = line.firstIndex(of: "]") else { return nil }
        let afterTimestamp = line.index(after: closingBracket)
        let remainder = line[afterTimestamp...].trimmingCharacters(in: .whitespaces)
        if remainder.hasPrefix(TranscriptSpeaker.you.displayLabel) {
            let text = remainder.dropFirst(TranscriptSpeaker.you.displayLabel.count).trimmingCharacters(in: .whitespaces)
            return "You: \(text)"
        }
        if remainder.hasPrefix(TranscriptSpeaker.others.displayLabel) {
            let text = remainder.dropFirst(TranscriptSpeaker.others.displayLabel.count).trimmingCharacters(in: .whitespaces)
            return "Them: \(text)"
        }
        return nil
    }

    private func pruneTail(now: Date) {
        let cutoff = now.addingTimeInterval(-displayWindowSeconds)
        if let firstIndex = tailChunks.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstIndex > 0 {
                tailChunks.removeFirst(firstIndex)
                chunkIDs.removeFirst(min(firstIndex, chunkIDs.count))
            }
        } else {
            tailChunks.removeAll()
            chunkIDs.removeAll()
        }
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
