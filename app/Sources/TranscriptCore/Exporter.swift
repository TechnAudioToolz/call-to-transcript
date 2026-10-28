import AppKit
import CoreText
import Foundation

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case pdf, docx, txt, srt, vtt

    public var fileExtension: String { rawValue }

    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "Word (DOCX)"
        case .txt: return "Plain text (TXT)"
        case .srt: return "Subtitles (SRT)"
        case .vtt: return "Web subtitles (VTT)"
        }
    }
}

public struct ExportOptions: Sendable {
    /// [1:23] before each paragraph, so a passage is easy to find in the video again
    public var timestamps = true

    public init(timestamps: Bool = true) {
        self.timestamps = timestamps
    }
}

public enum Exporter {
    public static func write(_ transcript: Transcript, as format: ExportFormat, to url: URL,
                             options: ExportOptions = ExportOptions()) throws {
        switch format {
        case .txt: try Data(text(transcript, options).utf8).write(to: url, options: .atomic)
        case .srt: try Data(subtitles(transcript, webVTT: false).utf8).write(to: url, options: .atomic)
        case .vtt: try Data(subtitles(transcript, webVTT: true).utf8).write(to: url, options: .atomic)
        case .docx: try docx(transcript, options).write(to: url, options: .atomic)
        case .pdf: try pdf(transcript, options).write(to: url, options: .atomic)
        }
    }

    static func heading(_ t: Transcript) -> [String] {
        let date = DateFormatter.localizedString(from: t.created, dateStyle: .medium, timeStyle: .none)
        return ["Source: \(t.sourceFile)",
                "Length: \(clock(t.duration)) · \(t.wordCount) words · \(t.speakers.count) speaker\(t.speakers.count == 1 ? "" : "s")",
                "Transcribed \(date) with \(t.engine), word for word"]
    }

    // MARK: plain text

    public static func text(_ t: Transcript, _ options: ExportOptions = ExportOptions()) -> String {
        var out = t.title + "\n" + heading(t).joined(separator: "\n") + "\n\n"
        for p in t.paragraphs {
            out += (options.timestamps ? "[\(clock(p.start))] " : "") + t.name(of: p.speaker) + ":\n" + p.text + "\n\n"
        }
        return out
    }

    // MARK: subtitles

    /// Cues of up to about 7 seconds or two subtitle lines, each starting with who is speaking.
    static func subtitles(_ t: Transcript, webVTT: Bool) -> String {
        func stamp(_ s: Double) -> String {
            let ms = Int((s * 1000).rounded())
            return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, webVTT ? "." : ",", ms % 1000)
        }
        var cues: [(start: Double, end: Double, text: String)] = []
        for p in t.paragraphs {
            var words: [Word] = []
            func flush() {
                guard let first = words.first, let last = words.last else { return }
                cues.append((first.start, last.end, t.name(of: p.speaker) + ": " + words.map(\.text).joined(separator: " ")))
                words = []
            }
            for word in p.words {
                if let first = words.first,
                   word.end - first.start > 7 || (words.map(\.text).joined(separator: " ").count + word.text.count > 84)
                    || (words.last.map { ".?!".contains($0.text.last ?? " ") } ?? false && word.start - first.start > 2) {
                    flush()
                }
                words.append(word)
            }
            flush()
        }
        var out = webVTT ? "WEBVTT\n\n" : ""
        for (i, cue) in cues.enumerated() {
            out += (webVTT ? "" : "\(i + 1)\n") + "\(stamp(cue.start)) --> \(stamp(max(cue.end, cue.start + 0.5)))\n\(cue.text)\n\n"
        }
        return out
    }

    // MARK: Word

    static func docx(_ t: Transcript, _ options: ExportOptions) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func run(_ text: String, bold: Bool = false, size: Int = 22, color: String? = nil) -> String {
            var props = "<w:sz w:val=\"\(size)\"/>"
            if bold { props = "<w:b/>" + props }
            if let color { props += "<w:color w:val=\"\(color)\"/>" }
            return "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r>"
        }
        func para(_ runs: String, after: Int = 120, keepNext: Bool = false) -> String {
            "<w:p><w:pPr>\(keepNext ? "<w:keepNext/>" : "")<w:spacing w:after=\"\(after)\"/></w:pPr>\(runs)</w:p>"
        }
        var body = para(run(t.title, bold: true, size: 36), after: 160)
        for line in heading(t) { body += para(run(line, size: 18, color: "666666"), after: 40) }
        body += para("", after: 200)
        for p in t.paragraphs {
            let time = options.timestamps ? run("  " + clock(p.start), size: 18, color: "888888") : ""
            body += para(run(t.name(of: p.speaker), bold: true) + time, after: 40, keepNext: true)
            body += para(run(p.text), after: 220)
        }
        let document = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)\
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
            w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
            """
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr>\
            <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:lang w:val="en-US"/></w:rPr>\
            </w:rPrDefault></w:docDefaults></w:styles>
            """
        let types = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
            </Types>
            """
        let rels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
            </Relationships>
            """
        let documentRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """
        let core = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(esc(t.title))</dc:title>\
            <dc:creator>Transcript Maker</dc:creator></cp:coreProperties>
            """
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", types)
        zip.add("_rels/.rels", rels)
        zip.add("docProps/core.xml", core)
        zip.add("word/_rels/document.xml.rels", documentRels)
        zip.add("word/styles.xml", styles)
        zip.add("word/document.xml", document)
        return zip.finish()
    }

    // MARK: PDF

    static func pdf(_ t: Transcript, _ options: ExportOptions) -> Data {
        let body = NSFont(name: "Georgia", size: 11) ?? .systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 10.5)
        let small = NSFont.systemFont(ofSize: 9)
        let grey = NSColor(white: 0.4, alpha: 1)
        func style(after: CGFloat, keepNext: Bool = false) -> NSParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.paragraphSpacing = after
            s.lineSpacing = 2
            return s
        }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: t.title + "\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18), .paragraphStyle: style(after: 6)]))
        for line in heading(t) {
            text.append(NSAttributedString(string: line + "\n", attributes: [.font: small, .foregroundColor: grey, .paragraphStyle: style(after: 1)]))
        }
        text.append(NSAttributedString(string: "\n", attributes: [.font: small]))
        for p in t.paragraphs {
            text.append(NSAttributedString(string: t.name(of: p.speaker), attributes: [.font: bold, .paragraphStyle: style(after: 2)]))
            if options.timestamps {
                text.append(NSAttributedString(string: "   " + clock(p.start), attributes: [.font: small, .foregroundColor: grey]))
            }
            text.append(NSAttributedString(string: "\n", attributes: [.font: bold, .paragraphStyle: style(after: 2)]))
            text.append(NSAttributedString(string: p.text + "\n", attributes: [.font: body, .paragraphStyle: style(after: 10)]))
        }

        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, [kCGPDFContextTitle: t.title, kCGPDFContextCreator: "Transcript Maker"] as CFDictionary)
        else { return Data() }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frameRect = page.insetBy(dx: 72, dy: 72)
        var position = 0
        var number = 1
        while position < text.length {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let shown = CTFrameGetVisibleStringRange(frame).length
            let footer = NSAttributedString(string: "\(t.title) · page \(number)", attributes: [.font: small, .foregroundColor: grey])
            let line = CTLineCreateWithAttributedString(footer)
            context.textPosition = CGPoint(x: 72, y: 40)
            CTLineDraw(line, context)
            context.endPDFPage()
            guard shown > 0 else { break }
            position += shown
            number += 1
        }
        context.closePDF()
        return data as Data
    }
}

/// A minimal ZIP writer (files stored uncompressed), enough for a .docx.
struct ZipWriter {
    private var data = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    mutating func add(_ name: String, _ text: String) {
        let content = Data(text.utf8)
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(content)
        let offset = UInt32(data.count)
        var local = Data()
        local.append(le32(0x04034b50)); local.append(le16(20)); local.append(le16(0x0800)); local.append(le16(0))
        local.append(le16(0)); local.append(le16(0x21))  // time, date: 1980-01-01
        local.append(le32(crc)); local.append(le32(UInt32(content.count))); local.append(le32(UInt32(content.count)))
        local.append(le16(UInt16(nameBytes.count))); local.append(le16(0))
        data.append(local); data.append(nameBytes); data.append(content)

        directory.append(le32(0x02014b50)); directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800))
        directory.append(le16(0)); directory.append(le16(0)); directory.append(le16(0x21))
        directory.append(le32(crc)); directory.append(le32(UInt32(content.count))); directory.append(le32(UInt32(content.count)))
        directory.append(le16(UInt16(nameBytes.count))); directory.append(le16(0)); directory.append(le16(0))
        directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0)); directory.append(le32(offset))
        directory.append(nameBytes)
        count += 1
    }

    func finish() -> Data {
        var out = data
        out.append(directory)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0)); out.append(le16(count)); out.append(le16(count))
        out.append(le32(UInt32(directory.count))); out.append(le32(UInt32(data.count))); out.append(le16(0))
        return out
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
