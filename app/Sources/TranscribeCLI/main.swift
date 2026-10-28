import Foundation
import TranscriptCore

// transcribe-cli VIDEO [--speakers N] [--cleanup off|gentle|strong] [--out FOLDER] [--json FILE] [--progress]
//   Writes VIDEO's transcript as JSON, PDF, DOCX, TXT, SRT and VTT into FOLDER (default: next to the video).
//   --json FILE   write only the transcript JSON, to FILE (the app does this, then writes the other files itself)
//   --progress    also print machine-readable lines for the app: "@stage listening 0.42"
// transcribe-cli --me MIC --them SOUND [--title T] [--names "Me|Client"] [--speakers N] … : a recorded call, the
//   microphone and the Mac's sound as two files; --speakers is then the number of people on the other side
// transcribe-cli --download-models   fetch every model into the models folder (for the offline edition)
// The app runs this as a separate process, so Pause can freeze it and Stop can end it at once.
setvbuf(stdout, nil, _IOLBF, 0)  // line by line, so the app sees progress as it happens

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--download-models") {  // for make_offline_dmg.sh
    do {
        try await Pipeline().downloadAll(log: { print($0) })
        print("Models ready in \(ModelStore.folder.path)")
        exit(0)
    } catch {
        print("Failed: \(error.localizedDescription)")
        exit(1)
    }
}
let flagsWithValues = ["--speakers", "--out", "--json", "--cleanup", "--me", "--them", "--title", "--names"]
func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
let positional = args.enumerated().filter { i, arg in
    !arg.hasPrefix("--") && !(i > 0 && flagsWithValues.contains(args[i - 1]))
}.map(\.element)
let call = value("--me").flatMap { me in value("--them").map { (me: URL(fileURLWithPath: me), them: URL(fileURLWithPath: $0)) } }
guard let path = positional.first ?? call?.me.path else {
    print("usage: transcribe-cli VIDEO [--speakers N] [--cleanup off|gentle|strong] [--out FOLDER] [--json FILE] [--progress]")
    exit(2)
}
let input = URL(fileURLWithPath: path)
let options = PipelineOptions(speakers: value("--speakers").flatMap(Int.init),
                              cleanup: value("--cleanup").flatMap(Cleanup.init(rawValue:)) ?? .off)
let machine = args.contains("--progress")

final class StageMeter: @unchecked Sendable {
    var stage: PipelineStage?
    var shown = -1.0
}
let meter = StageMeter()

let started = Date()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-cli-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }
do {
    let stage: @Sendable (PipelineStage, Double) -> Void = { stage, fraction in
        if meter.stage != stage {
            meter.stage = stage
            meter.shown = -1
            print("\(stage.rawValue)…")
        }
        if machine, fraction - meter.shown >= 0.01 || (fraction >= 1 && meter.shown < 1) {
            meter.shown = fraction
            print("@stage \(stage) \(String(format: "%.3f", fraction))")
        }
    }
    let transcript: Transcript
    if let call {
        let names = (value("--names") ?? "Me|Client").split(separator: "|").map(String.init)
        transcript = try await Pipeline().runCall(
            me: call.me, them: call.them, title: value("--title") ?? call.me.deletingLastPathComponent().lastPathComponent,
            workFolder: work, options: options, names: (names.first ?? "Me", names.count > 1 ? names[1] : "Client"),
            stage: stage, log: { print($0) })
    } else {
        transcript = try await Pipeline().run(input, workFolder: work, options: options, stage: stage, log: { print($0) })
    }

    if let json = value("--json") {
        try transcript.save(URL(fileURLWithPath: json))
    } else {
        let folder = value("--out").map { URL(fileURLWithPath: $0) } ?? input.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = folder.appendingPathComponent(transcript.title.replacingOccurrences(of: "/", with: "-"))
        try transcript.save(stem.appendingPathExtension("json"))
        for format in ExportFormat.allCases {
            try Exporter.write(transcript, as: format, to: stem.appendingPathExtension(format.fileExtension))
        }
    }
    print(String(format: "Done in %.1f s: %d words, %d speaker%@", Date().timeIntervalSince(started),
                 transcript.wordCount, transcript.speakers.count, transcript.speakers.count == 1 ? "" : "s"))
} catch {
    print("Failed: \(error.localizedDescription)")
    exit(1)
}
