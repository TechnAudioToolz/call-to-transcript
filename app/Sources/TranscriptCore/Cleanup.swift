import Accelerate
import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Optional clean-up of the sound before listening. Off by default: the speech model was trained on noisy audio
/// and copes well, while clean-up can blur quiet words (and the "um"s a word-for-word transcript keeps).
public enum Cleanup: String, Codable, CaseIterable, Sendable {
    /// The sound as it is.
    case off
    /// Takes out rumble and hum below 80 Hz and evens out loud and quiet voices. Plain signal processing.
    case gentle
    /// Removes background noise and room echo with a small neural network (LocalVQE), then evens out voices.
    case strong

    public var label: String {
        switch self {
        case .off: return "Off"
        case .gentle: return "Gentle"
        case .strong: return "Strong"
        }
    }
}

enum SoundCleaner {
    static let sampleRate = AudioExtractor.sampleRate
    /// 30 s at a time, so hours of audio need little memory.
    static let block = AVAudioFrameCount(30 * 16_000)

    /// Reads `input` (16 kHz mono WAV) and writes the cleaned sound to `output`.
    static func clean(_ input: URL, to output: URL, level: Cleanup, models: URL,
                      progress: @Sendable (Double) -> Void) async throws {
        let source = try AVAudioFile(forReading: input)
        let total = Double(source.length)
        let format = source.processingFormat
        var samples: [Float] = []
        samples.reserveCapacity(Int(source.length))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: block)
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }

        if level == .strong {
            // On the graphics chip: the CPU path crashes on macOS 14 (an Apple bug) and is slower anyway.
            let vqe = try await LocalVqeManager(config: LocalVqeConfig(computeUnits: .cpuAndGPU), directory: models)
            let stream = try await vqe.makeStream()
            var cleaned: [Float] = []
            cleaned.reserveCapacity(samples.count)
            let step = Int(block)
            var start = 0
            while start < samples.count {
                let end = min(samples.count, start + step)
                let piece = Array(samples[start..<end])
                cleaned.append(contentsOf: try await stream.enhance(mic: piece, reference: [Float](repeating: 0, count: piece.count)))
                progress(Double(end) / total * 0.9)
                start = end
            }
            cleaned.append(contentsOf: try await stream.flush())
            // the model's output lags its input by one hop: line them back up so word times stay right
            let delay = LocalVqeManager.outputDelaySamples
            samples = Array(cleaned.dropFirst(min(delay, cleaned.count)))
            samples.append(contentsOf: [Float](repeating: 0, count: max(0, Int(total) - samples.count)))
            samples = Array(samples.prefix(Int(total)))
        } else {
            highPass(&samples, cutoff: 80)
            progress(0.5)
        }
        evenOut(&samples)
        progress(1)

        let file = try AVAudioFile(forWriting: output, settings: source.fileFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        var position = 0
        while position < samples.count {
            let count = min(Int(block), samples.count - position)
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            out.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { all in
                out.floatChannelData![0].update(from: all.baseAddress! + position, count: count)
            }
            try file.write(from: out)
            position += count
        }
    }

    /// Second-order Butterworth high-pass: takes out rumble, traffic, air conditioning and mains hum.
    static func highPass(_ x: inout [Float], cutoff: Double) {
        let w = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w), alpha = sin(w) / (2 * 0.7071)
        let a0 = 1 + alpha
        let coefficients = [(1 + cosw) / 2 / a0, -(1 + cosw) / a0, (1 + cosw) / 2 / a0, -2 * cosw / a0, (1 - alpha) / a0]
        guard let setup = vDSP_biquad_CreateSetup(coefficients, 1) else { return }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 4)
        var output = [Float](repeating: 0, count: x.count)
        vDSP_biquad(setup, &delay, x, 1, &output, 1, vDSP_Length(x.count))
        x = output
    }

    /// Evens out loudness over about a second, so a quiet speaker far from the microphone comes up to the
    /// level of a loud one. Pauses and background noise aren't pulled up (gain is capped near the noise floor),
    /// and peaks are kept below clipping.
    static func evenOut(_ x: inout [Float]) {
        let frame = 800  // 50 ms
        let frames = x.count / frame
        guard frames > 20 else { return }
        var rms = [Float](repeating: 0, count: frames)
        x.withUnsafeBufferPointer { p in
            for i in 0..<frames { vDSP_rmsqv(p.baseAddress! + i * frame, 1, &rms[i], vDSP_Length(frame)) }
        }
        let sorted = rms.sorted()
        let noiseFloor = max(sorted[frames / 10], 1e-5)   // the quietest tenth: room tone
        let speech = max(sorted[frames * 9 / 10], 1e-4)   // the loudest tenth: speech at its usual level
        let target: Float = 0.1                           // about -20 dBFS
        // a 1-second moving average, so the gain follows speakers, not syllables
        var smooth = [Float](repeating: 0, count: frames)
        let half = 10
        var sum: Float = 0
        for i in 0..<min(frames, half) { sum += rms[i] }
        for i in 0..<frames {
            if i + half < frames { sum += rms[i + half] }
            if i - half - 1 >= 0 { sum -= rms[i - half - 1] }
            let count = Float(min(frames - 1, i + half) - max(0, i - half) + 1)
            smooth[i] = sum / count
        }
        let maxGain = min(8, target / (noiseFloor * 3))   // never lift room tone above a third of the target
        var gains = smooth.map { level -> Float in
            let g = target / max(level, noiseFloor * 3)
            return max(0.5, min(max(1, maxGain), g))
        }
        // overall level first: a recording that's quiet throughout is simply turned up
        let overall = target / speech
        if overall < 1 { gains = gains.map { min($0, max(overall, 0.5)) } }
        // gain changes are spread over each 50 ms frame, so there are no clicks
        for i in 0..<frames {
            let from = i == 0 ? gains[0] : gains[i - 1]
            let to = gains[i]
            for j in 0..<frame {
                let k = i * frame + j
                x[k] *= from + (to - from) * Float(j) / Float(frame)
            }
        }
        if frames * frame < x.count {
            for k in frames * frame..<x.count { x[k] *= gains[frames - 1] }
        }
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(x.count))
        if peak > 0.98 {
            // soft limit only the loud moments
            for k in x.indices where abs(x[k]) > 0.7 {
                let sign: Float = x[k] < 0 ? -1 : 1
                x[k] = sign * (0.7 + 0.28 * tanh((abs(x[k]) - 0.7) / 0.28))
            }
        }
    }
}
