import AVFoundation
import Foundation

/// Takes the sound out of a video or audio file as 16 kHz mono WAV, the form the speech models read.
public enum AudioExtractor {
    public static let sampleRate = 16_000.0

    /// The Mac's own decoder handles MP4, MOV, M4V, M4A, MP3, WAV, AIFF and CAF. Anything else (MKV, WebM,
    /// AVI, FLAC, OGG…) goes through ffmpeg. Returns the length in seconds.
    @discardableResult
    public static func extract(_ input: URL, to output: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Double {
        try? FileManager.default.removeItem(at: output)
        do {
            return try await extractWithAVFoundation(input, to: output, progress: progress)
        } catch TranscriptError.noAudio(let url) {
            throw TranscriptError.noAudio(url)
        } catch {
            guard let ffmpeg = ffmpegPath else { throw error }
            return try extractWithFFmpeg(ffmpeg, input, to: output)
        }
    }

    private static func extractWithAVFoundation(_ input: URL, to output: URL,
                                                progress: (@Sendable (Double) -> Void)?) async throws -> Double {
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            // a file AVFoundation can open but sees no sound in may still be one only ffmpeg understands
            if (try? await asset.load(.isReadable)) == true, ffmpegPath == nil { throw TranscriptError.noAudio(input) }
            throw TranscriptError.unreadable(input, "no sound track the Mac can decode")
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output16k = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output16k)
        guard reader.startReading() else {
            throw TranscriptError.unreadable(input, reader.error?.localizedDescription ?? "unknown error")
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        var written = 0.0
        while let sample = output16k.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let frames = bytes / MemoryLayout<Float>.size
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: buffer.floatChannelData![0])
            try file.write(from: buffer)
            written += Double(frames) / sampleRate
            if duration > 0 { progress?(min(1, written / duration)) }
        }
        if reader.status == .failed {
            throw TranscriptError.unreadable(input, reader.error?.localizedDescription ?? "decoding failed")
        }
        return written
    }

    private static func extractWithFFmpeg(_ ffmpeg: String, _ input: URL, to output: URL) throws -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                             "-vn", "-map", "0:a:0", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if message.contains("matches no streams") { throw TranscriptError.noAudio(input) }
            throw TranscriptError.unreadable(input, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let file = try AVAudioFile(forReading: output)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// The ffmpeg inside the app, or one installed with Homebrew.
    public static var ffmpegPath: String? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("bin/ffmpeg").path,
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
