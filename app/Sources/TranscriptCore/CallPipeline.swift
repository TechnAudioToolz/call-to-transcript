import Foundation

extension Pipeline {
    /// A recorded call: `me` is the microphone, `them` the Mac's sound (the other side of the call), both
    /// starting at the same moment. Each is heard on its own, so who said what comes from the track, not from
    /// telling voices apart. Only when more than one person is on the other side are their voices told apart.
    /// `options.speakers` is the number of people on the other side (nil: work it out).
    public func runCall(me: URL, them: URL, title: String, workFolder: URL, options: PipelineOptions = PipelineOptions(),
                        names: (me: String, them: String) = ("Me", "Client"),
                        stage: @escaping @Sendable (PipelineStage, Double) -> Void,
                        log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Transcript {
        stage(.loading, 0)
        log("Models: \(ModelStore.folder.path)")
        try await prepareSpeech(log: log)

        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        var tracks: [(wav: URL, duration: Double)] = []
        for (i, input) in [me, them].enumerated() {
            stage(.extracting, Double(i) / 2)
            var wav = workFolder.appendingPathComponent("track\(i)-16k.wav")
            let duration = try await AudioExtractor.extract(input, to: wav) { stage(.extracting, (Double(i) + $0) / 2) }
            if options.cleanup != .off {
                stage(.cleaning, Double(i) / 2)
                let cleaned = workFolder.appendingPathComponent("track\(i)-clean.wav")
                try await SoundCleaner.clean(wav, to: cleaned, level: options.cleanup, models: ModelStore.folder) {
                    stage(.cleaning, (Double(i) + $0) / 2)
                }
                wav = cleaned
            }
            tracks.append((wav, duration))
        }
        log("Recording: \(clock(tracks[0].duration)) from the microphone, \(clock(tracks[1].duration)) from the Mac's sound")

        var heard: [[Word]] = []
        for (i, track) in tracks.enumerated() {
            log(i == 0 ? "Listening to you (the microphone)…" : "Listening to the other side (the Mac's sound)…")
            stage(.listening, Double(i) / 2)
            heard.append(try await listen(track.wav, duration: track.duration,
                                          progress: { stage(.listening, (Double(i) + $0) / 2) }, log: log))
        }
        let echoes = CallMerger.removeEchoes(&heard[0], heard: heard[1])
        if echoes > 0 { log("Left out \(echoes) word\(echoes == 1 ? "" : "s") the microphone picked up from the speakers") }
        guard !heard[0].isEmpty || !heard[1].isEmpty else { throw TranscriptError.nothingHeard }

        // who on the other side said each of their words: one person unless set otherwise
        var themSpeakers = [Int](repeating: 0, count: heard[1].count)
        var themCount = 1
        if options.speakers != 1, !heard[1].isEmpty {
            stage(.speakers, 0)
            let started = Date()
            try await prepareVoices(speakers: options.speakers)
            guard let diarizer else { throw TranscriptError.modelsMissing("voice model") }
            let segments = try await diarizer.process(tracks[1].wav) { done, total in
                stage(.speakers, Double(done) / Double(max(1, total)))
            }.segments
            let merged = Merger.transcript(words: heard[1], segments: segments)
            themCount = merged.speakers.count
            themSpeakers = merged.paragraphs.flatMap { p in p.words.map { _ in p.speaker } }
            log(String(format: "Found %d voice%@ on the other side (%.1f s)", themCount, themCount == 1 ? "" : "s",
                       Date().timeIntervalSince(started)))
        }

        stage(.writing, 0)
        var transcript = CallMerger.transcript(me: heard[0], them: heard[1], themSpeakers: themSpeakers)
        transcript.speakers = [names.me] + (themCount == 1 ? [names.them] : (1...themCount).map { "\(names.them) \($0)" })
        transcript.title = title
        transcript.sourceFile = "call recording (\(me.lastPathComponent) and \(them.lastPathComponent))"
        transcript.duration = max(tracks[0].duration, tracks[1].duration)
        transcript.engine = "Parakeet (\(ModelStore.parakeetVersion))"
            + (options.cleanup == .off ? "" : ", sound clean-up: \(options.cleanup.label.lowercased())")
        try? FileManager.default.removeItem(at: workFolder)
        return transcript
    }
}

/// Puts the two sides of a call together: speaker 0 is the microphone, 1… the other side.
enum CallMerger {
    /// Without headphones the microphone also hears the other side through the speakers. Those words come out
    /// in both tracks starting at about the same moment, so they are taken out of the microphone's. A lone short word
    /// both sides say at once ("yeah", "okay") stays: that's usually two people agreeing.
    /// Returns how many words were taken out.
    static func removeEchoes(_ me: inout [Word], heard them: [Word]) -> Int {
        guard !me.isEmpty, !them.isEmpty else { return 0 }
        func plain(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        // starts, not middles: the last word before a pause can be given an end seconds later
        let theirs = them.map { (text: plain($0.text), start: $0.start) }
        let echo: [Bool] = me.map { word in
            let text = plain(word.text)
            return !text.isEmpty && theirs.contains { $0.text == text && abs($0.start - word.start) < 1.0 }
        }
        var drop = [Bool](repeating: false, count: me.count)
        var i = 0
        while i < me.count {
            guard echo[i] else { i += 1; continue }
            var j = i
            while j + 1 < me.count, echo[j + 1] { j += 1 }
            if j > i || plain(me[i].text).count > 4 {
                for k in i...j { drop[k] = true }
            }
            i = j + 1
        }
        let before = me.count
        me = zip(me, drop).filter { !$0.1 }.map(\.0)
        return before - me.count
    }

    /// Each side's words are cut into stretches (at sentence ends and pauses of a second), the stretches are put
    /// in the order they were said, and neighbouring stretches by the same person join into paragraphs. A quick
    /// "mm-hmm" while the other person talks lands after the sentence it was said during.
    static func transcript(me: [Word], them: [Word], themSpeakers: [Int]) -> Transcript {
        var stretches: [Paragraph] = []
        func cut(_ words: [Word], speaker: (Int) -> Int) {
            for (i, word) in words.enumerated() {
                let s = speaker(i)
                if var current = stretches.last, current.speaker == s, let last = current.words.last,
                   word.start - last.end < 1.0, !(last.text.last.map { ".?!".contains($0) } ?? false) {
                    current.words.append(word)
                    stretches[stretches.count - 1] = current
                } else {
                    stretches.append(Paragraph(speaker: s, words: [word]))
                }
            }
        }
        cut(me) { _ in 0 }
        cut(them) { 1 + (themSpeakers.indices.contains($0) ? themSpeakers[$0] : 0) }
        stretches.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }

        var paragraphs: [Paragraph] = []
        for stretch in stretches {
            if var current = paragraphs.last, current.speaker == stretch.speaker,
               !Merger.shouldBreak(current, before: stretch.words[0]) {
                current.words += stretch.words
                paragraphs[paragraphs.count - 1] = current
            } else {
                paragraphs.append(stretch)
            }
        }
        return Transcript(title: "", sourceFile: "", duration: 0, engine: "", created: Date(),
                          speakers: [], paragraphs: paragraphs)
    }
}
