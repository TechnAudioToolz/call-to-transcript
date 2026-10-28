import Foundation

/// One recognised word, with when it was said (seconds from the start) and how sure the recogniser was (0-1).
public struct Word: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float

    public init(text: String, start: Double, end: Double, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// What one person said without being interrupted (long turns are split at sentence ends).
public struct Paragraph: Codable, Sendable, Equatable {
    /// Index into `Transcript.speakers`.
    public var speaker: Int
    public var words: [Word]

    public var start: Double { words.first?.start ?? 0 }
    public var end: Double { words.last?.end ?? 0 }
    public var text: String { words.map(\.text).joined(separator: " ") }
}

/// A finished transcript. Saved as JSON next to the exports, so speakers can be renamed and the PDF and DOCX
/// written again without listening to the video again.
public struct Transcript: Codable, Sendable {
    public var title: String
    public var sourceFile: String
    public var duration: Double
    /// e.g. "Parakeet (ultra)" or "Whisper large-v3"
    public var engine: String
    public var created: Date
    /// "Person 1", "Person 2"… in the order they first speak; the user can rename them.
    public var speakers: [String]
    public var paragraphs: [Paragraph]

    public var wordCount: Int { paragraphs.reduce(0) { $0 + $1.words.count } }

    public func name(of speaker: Int) -> String {
        speakers.indices.contains(speaker) ? speakers[speaker] : "Person \(speaker + 1)"
    }

    public static func load(_ url: URL) throws -> Transcript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Transcript.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// 83.4 -> "1:23", 4000 -> "1:06:40"
public func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

public enum TranscriptError: LocalizedError {
    case noAudio(URL)
    case unreadable(URL, String)
    case modelsMissing(String)
    case nothingHeard

    public var errorDescription: String? {
        switch self {
        case .noAudio(let url): return "\(url.lastPathComponent) has no sound track"
        case .unreadable(let url, let why): return "Can't read \(url.lastPathComponent): \(why)"
        case .modelsMissing(let what): return "The \(what) isn't installed"
        case .nothingHeard: return "No speech was heard"
        }
    }
}
