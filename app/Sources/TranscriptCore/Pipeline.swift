import CoreML
import FluidAudio
import Foundation

/// Where the speech models live: inside the app for the offline edition, otherwise downloaded once into
/// ~/Library/Application Support/Transcript Maker/models (shared with Transcript Maker, so the 700 MB of models
/// are fetched only once on a Mac with both apps).
public enum ModelStore {
    public static var folder: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("models"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcript Maker/models")
    }

    /// The Parakeet build used for English: "ultra" has the lowest error rate of the Parakeet family
    /// (2.1 % on LibriSpeech test-clean, 3.8 % on test-other) and runs on macOS 14.
    static let parakeetVersion = AsrModelVersion.ultra

    static var parakeetFolder: URL { folder.appendingPathComponent(Repo.parakeetUltra.folderName) }

    public static var parakeetInstalled: Bool { AsrModels.modelsExist(at: parakeetFolder, version: parakeetVersion) }
}

public struct PipelineOptions: Sendable {
    /// Exact number of people talking, when known; nil to let the app work it out.
    public var speakers: Int?
    /// Clean up the sound before listening (off unless chosen).
    public var cleanup: Cleanup = .off
    /// Words that should be spelled a particular way (names, jargon); used to steer the recogniser.
    public var vocabulary: [String] = []

    public init(speakers: Int? = nil, cleanup: Cleanup = .off) {
        self.speakers = speakers
        self.cleanup = cleanup
    }
}

/// What the pipeline is doing, for the progress bar and the log.
public enum PipelineStage: String, Sendable {
    case loading = "Loading the speech models"
    case extracting = "Taking out the sound"
    case cleaning = "Cleaning up the sound"
    case listening = "Listening for words"
    case speakers = "Telling the voices apart"
    case writing = "Writing the transcript"
}

/// Video in, transcript out: sound -> words with times -> who spoke when -> paragraphs per speaker.
public actor Pipeline {
    private var asr: AsrManager?
    var diarizer: OfflineDiarizerManager?  // CallPipeline.swift uses it too

    public init() {}

    /// Loads (and the first time, downloads) the models. Takes a few seconds; the first load on a Mac also
    /// compiles them for its Neural Engine, which takes a minute or two.
    public func prepare(log: @Sendable (String) -> Void = { _ in }) async throws {
        try await prepareSpeech(log: log)
        try await prepareVoices()
    }

    /// Every model the app can use, including sound clean-up's: for building the offline edition.
    public func downloadAll(log: @Sendable (String) -> Void = { _ in }) async throws {
        try await prepare(log: log)
        _ = try await LocalVqeManager(config: LocalVqeConfig(computeUnits: .cpuAndGPU), directory: ModelStore.folder)
    }

    /// The speech recogniser. `encoderUnits` nil means its usual place, the Neural Engine.
    func prepareSpeech(encoderUnits: MLComputeUnits? = nil, log: @Sendable (String) -> Void) async throws {
        guard asr == nil else { return }
        let folder = ModelStore.parakeetFolder
        let models: AsrModels
        if ModelStore.parakeetInstalled {
            models = try await AsrModels.load(from: folder, version: ModelStore.parakeetVersion, encoderComputeUnits: encoderUnits)
        } else {
            log("Downloading the speech recognition model (about 650 MB, once)…")
            models = try await AsrModels.downloadAndLoad(to: folder, version: ModelStore.parakeetVersion,
                                                         encoderComputeUnits: encoderUnits)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    /// The models that tell voices apart.
    func prepareVoices(speakers: Int? = nil) async throws {
        let manager = OfflineDiarizerManager(config: Self.voiceSettings(speakers: speakers))
        try await manager.prepareModels(directory: ModelStore.folder)
        diarizer = manager
    }

    static func voiceSettings(speakers: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        // Windows every second instead of every two: catches quick replies ("Have you thought about…? I haven't.")
        // that the default folds into the speaker around them. Twice the work, about 5 s per minute of audio.
        config.segmentation.stepRatio = 0.1
        if let speakers { config.clustering.numSpeakers = speakers }
        return config
    }

    public func run(_ input: URL, workFolder: URL, options: PipelineOptions = PipelineOptions(),
                    stage: @escaping @Sendable (PipelineStage, Double) -> Void,
                    log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Transcript {
        stage(.loading, 0)
        log("Models: \(ModelStore.folder.path)")
        // one model set at a time: loading the voice models while the speech model is still being readied
        // for the Neural Engine has made the speech model fail
        try await prepareSpeech(log: log)
        guard asr != nil else { throw TranscriptError.modelsMissing("speech model") }

        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        var wav = workFolder.appendingPathComponent("audio-16k.wav")
        stage(.extracting, 0)
        var started = Date()
        let duration = try await AudioExtractor.extract(input, to: wav) { stage(.extracting, $0) }
        log(String(format: "Sound taken out: %@ long (%.1f s)", clock(duration), Date().timeIntervalSince(started)))
        let original = wav
        if options.cleanup != .off {
            stage(.cleaning, 0)
            started = Date()
            let cleaned = workFolder.appendingPathComponent("audio-clean.wav")
            try await SoundCleaner.clean(original, to: cleaned, level: options.cleanup, models: ModelStore.folder) { stage(.cleaning, $0) }
            wav = cleaned
            log(String(format: "Sound cleaned up (%@, %.1f s)", options.cleanup.label.lowercased(), Date().timeIntervalSince(started)))
        }

        stage(.listening, 0)
        let words = try await listen(wav, duration: duration, progress: { stage(.listening, $0) }, log: log)
        guard !words.isEmpty else { throw TranscriptError.nothingHeard }

        stage(.speakers, 0)
        started = Date()
        var segments: [TimedSpeakerSegment] = []
        if let count = options.speakers, count <= 1 {
            log("One speaker, as set")
        } else {
            try await prepareVoices(speakers: options.speakers)
            guard let diarizer else { throw TranscriptError.modelsMissing("voice model") }
            // TM_VOICES_FROM=original: tell voices apart from the sound before clean-up (for testing)
            let voices = ProcessInfo.processInfo.environment["TM_VOICES_FROM"] == "original" ? original : wav
            segments = try await diarizer.process(voices) { done, total in stage(.speakers, Double(done) / Double(max(1, total))) }.segments
            log(String(format: "Found %d voice%@ (%.1f s)", Set(segments.map(\.speakerId)).count,
                       Set(segments.map(\.speakerId)).count == 1 ? "" : "s", Date().timeIntervalSince(started)))
        }

        stage(.writing, 0)
        var transcript = Merger.transcript(words: words, segments: segments)
        transcript.title = input.deletingPathExtension().lastPathComponent
        transcript.sourceFile = input.lastPathComponent
        transcript.duration = duration
        transcript.engine = "Parakeet (\(ModelStore.parakeetVersion))"
            + (options.cleanup == .off ? "" : ", sound clean-up: \(options.cleanup.label.lowercased())")
        try? FileManager.default.removeItem(at: workFolder)  // about 2 MB a minute; the transcript keeps the times
        return transcript
    }

    /// The words in a 16 kHz mono WAV, with their times.
    func listen(_ wav: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void,
                log: @escaping @Sendable (String) -> Void) async throws -> [Word] {
        try await prepareSpeech(log: log)
        guard let asr else { throw TranscriptError.modelsMissing("speech model") }
        let started = Date()
        let progressTask = Task {
            for try await fraction in await asr.transcriptionProgressStream { progress(fraction) }
        }
        defer { progressTask.cancel() }
        var state = TdtDecoderState.make()
        let result: ASRResult
        do {
            result = try await asr.transcribeDiskBacked(wav, decoderState: &state)
        } catch {
            // Right after the app is installed or updated, the Mac compiles the models for its Neural Engine and
            // the first prediction can fail. Loading them again and starting over has always worked.
            log("The speech model hiccupped (\(error.localizedDescription)); starting over on the graphics chip")
            self.asr = nil
            try await prepareSpeech(encoderUnits: .cpuAndGPU, log: log)
            guard let fresh = self.asr else { throw error }
            state = TdtDecoderState.make()
            result = try await fresh.transcribeDiskBacked(wav, decoderState: &state)
        }
        let words = Self.words(from: result.tokenTimings ?? [])
        log(String(format: "Heard %d words (%.1f s, %.0fx faster than real time)",
                   words.count, Date().timeIntervalSince(started), duration / max(0.1, Date().timeIntervalSince(started))))
        return words
    }

    /// Joins the recogniser's word pieces ("▁ex", "amp", "le") into whole words with start and end times.
    /// A piece that starts a new word begins with a space; numbers come as a lone space piece and then the
    /// digits ("▁about", "▁", "2", "4" is "about 24").
    static func words(from tokens: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        var confidences: [Float] = []
        var newWord = true
        func finishWord() {
            if let last = words.indices.last, !confidences.isEmpty {
                words[last].confidence = confidences.reduce(0, +) / Float(confidences.count)
            }
            confidences = []
        }
        for token in tokens {
            let piece = token.token.replacingOccurrences(of: "▁", with: " ")
            let text = piece.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix(" ") { newWord = true }
            guard !text.isEmpty else { continue }
            if newWord || words.isEmpty {
                finishWord()
                words.append(Word(text: text, start: token.startTime, end: token.endTime, confidence: token.confidence))
                newWord = false
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = token.endTime
            }
            confidences.append(token.confidence)
        }
        finishWord()
        // "i" on its own is always "I" in English; the recogniser sometimes writes it small
        for i in words.indices {
            let w = words[i].text
            if w == "i" || w.hasPrefix("i'") { words[i].text = "I" + w.dropFirst() }
        }
        return words
    }
}

/// Puts each word with the voice that was speaking when it was said, and groups the words into paragraphs.
enum Merger {
    static func transcript(words: [Word], segments: [TimedSpeakerSegment]) -> Transcript {
        let segments = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var labels: [String: Int] = [:]  // diarizer's id -> Person number, in the order they first speak
        var previous = 0
        var speakerOfWord: [Int] = words.map { word in
            let id = speakerId(at: (word.start + word.end) / 2, in: segments)
            guard let id else { return previous }  // between voices: keep the last speaker
            if labels[id] == nil { labels[id] = labels.count }
            previous = labels[id]!
            return previous
        }
        smoothBlips(&speakerOfWord, words)
        snapChanges(&speakerOfWord, words)

        var paragraphs: [Paragraph] = []
        for (i, word) in words.enumerated() {
            let speaker = speakerOfWord[i]
            if var current = paragraphs.last, current.speaker == speaker, !shouldBreak(current, before: word) {
                current.words.append(word)
                paragraphs[paragraphs.count - 1] = current
            } else {
                paragraphs.append(Paragraph(speaker: speaker, words: [word]))
            }
        }
        let count = max(1, (speakerOfWord.max() ?? 0) + 1)
        return Transcript(title: "", sourceFile: "", duration: 0, engine: "", created: Date(),
                          speakers: (1...count).map { "Person \($0)" }, paragraphs: paragraphs)
    }

    /// The voice speaking at a moment, or the nearest one within a second.
    static func speakerId(at time: Double, in segments: [TimedSpeakerSegment]) -> String? {
        var best: (distance: Double, id: String)?
        for segment in segments {
            let start = Double(segment.startTimeSeconds), end = Double(segment.endTimeSeconds)
            if start > time + 1 { break }
            let distance = time < start ? start - time : (time > end ? time - end : 0)
            if distance == 0 { return segment.speakerId }
            if distance <= 1, distance < (best?.distance ?? .infinity) { best = (distance, segment.speakerId) }
        }
        return best?.id
    }

    /// One or two quick words given to someone else in the middle of a person's sentence are almost always
    /// a voice-matching slip, not a real interruption: give them back.
    static func smoothBlips(_ speakers: inout [Int], _ words: [Word]) {
        var i = 0
        while i < speakers.count {
            var j = i
            while j + 1 < speakers.count, speakers[j + 1] == speakers[i] { j += 1 }
            let length = j - i + 1
            if i > 0, j + 1 < speakers.count, speakers[i - 1] == speakers[j + 1], length <= 2,
               words[j].end - words[i].start < 0.8,
               words[i].start - words[i - 1].end < 0.3, words[j + 1].start - words[j].end < 0.3 {
                for k in i...j { speakers[k] = speakers[i - 1] }
            }
            i = j + 1
        }
    }

    /// The voice model's changes of speaker can land a word or two early or late ("…as well I | do so…" when
    /// "I do so" is the next person). People take turns at pauses and sentence ends, so each change moves to
    /// the best such spot within three words.
    static func snapChanges(_ speakers: inout [Int], _ words: [Word]) {
        func score(_ j: Int, from k: Int) -> Double {
            let gap = max(0, words[j].start - words[j - 1].end)
            let ending = words[j - 1].text.last
            let punctuation = ending.map { ".?!".contains($0) } ?? false ? 0.3 : (ending == "," ? 0.1 : 0)
            return min(gap, 1.5) + punctuation - 0.05 * Double(abs(j - k))
        }
        var k = 1
        while k < speakers.count {
            guard speakers[k] != speakers[k - 1] else { k += 1; continue }
            // stay between the neighbouring changes, so no turn disappears
            var low = k, high = k
            while low - 1 >= 1, k - (low - 1) <= 3, speakers[low - 2] == speakers[k - 1] { low -= 1 }
            while high + 1 < speakers.count, high + 1 - k <= 3, speakers[high + 1] == speakers[k] { high += 1 }
            var best = k
            for j in low...high where score(j, from: k) > score(best, from: k) + 0.05 { best = j }
            if best < k {
                for i in best..<k { speakers[i] = speakers[k] }
            } else if best > k {
                for i in k..<best { speakers[i] = speakers[k - 1] }
            }
            k = max(k, best) + 1
        }
    }

    /// Long stretches by one speaker are split at a sentence end after about a minute, or at a long pause.
    static func shouldBreak(_ paragraph: Paragraph, before word: Word) -> Bool {
        guard let last = paragraph.words.last else { return false }
        let sentenceEnded = last.text.last.map { ".?!".contains($0) } ?? false
        let pause = word.start - last.end
        return sentenceEnded && (paragraph.end - paragraph.start > 60 || pause > 3)
    }
}
