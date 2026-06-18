// Extracts readable text from a file for the `contents` condition.
//
// The `contents` condition exposes a single string match in the UI, but the
// text it matches against can come from several sources depending on the file
// type. `ContentExtractor` is the ordered pipeline that turns a path into text:
// plain files are read directly, PDFs use their text layer, Word/RTF documents
// are decoded with AppKit, and images are run through on-device OCR.
//
// Each extractor reports which `ContentStrategy` produced the text (surfaced in
// the Dry Run) and, when nothing readable is found, a short `message` explaining
// why — e.g. a file past the size limit. When no text can be extracted the
// result's `text` is `nil`, and the evaluator treats every operator (including
// the negative ones) as not matching, so a rule never matches on content it
// could not actually read.

import Foundation
import PDFKit
import Vision
import AppKit
import ZIPFoundation

/// How a file's text was obtained. Drives the Dry Run's per-condition detail.
/// Cases marked Phase 2 are reserved so the display and call sites don't need to
/// change when those extractors are added.
public enum ContentStrategy: String, Sendable {
    case plainText
    case pdfText
    case pdfOCR          // Phase 2 (scanned PDFs)
    case rtf
    case officeDocument  // .doc / .docx via AppKit
    case xlsx
    case pptx
    case iWork           // Phase 2
    case officeLegacy    // Phase 2
    case spotlight
    case imageOCR
    case none

    /// Human-readable label shown in the Dry Run details.
    public var label: String {
        switch self {
        case .plainText: return "Plain text"
        case .pdfText: return "PDF text"
        case .pdfOCR: return "PDF OCR"
        case .rtf: return "RTF"
        case .officeDocument: return "Word document"
        case .xlsx: return "Spreadsheet"
        case .pptx: return "Presentation"
        case .iWork: return "iWork document"
        case .officeLegacy: return "Office document"
        case .spotlight: return "Spotlight"
        case .imageOCR: return "Image OCR"
        case .none: return "No readable content"
        }
    }
}

/// The outcome of an extraction attempt. `text == nil` means nothing readable
/// was found; `message` carries a short reason for the Dry Run when relevant.
public struct ContentExtraction: Sendable {
    public let text: String?
    public let strategy: ContentStrategy
    public let message: String?

    public init(text: String?, strategy: ContentStrategy, message: String? = nil) {
        self.text = text
        self.strategy = strategy
        self.message = message
    }
}

public enum ContentExtractor {
    // Hard limits, kept together so they're easy to tune. Files over a limit
    // return no text with an explanatory message rather than being read.
    private static let plainTextMaxBytes: UInt64 = 50 * 1024 * 1024
    private static let pdfMaxBytes: UInt64 = 100 * 1024 * 1024
    private static let pdfMaxPages = 100
    private static let ocrImageMaxBytes: UInt64 = 25 * 1024 * 1024
    private static let ocrMaxDimension = 12_000
    private static let officeZipMaxBytes: UInt64 = 100 * 1024 * 1024

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "json", "xml", "yaml", "yml", "html", "css",
        "js", "ts", "swift", "rs", "py", "rb", "go", "java", "c", "cpp", "h", "log",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif",
    ]
    /// Formats with no in-process text extractor that macOS can still index.
    /// For these we fall back to a Spotlight search, which only answers the
    /// `contains` operator (see `spotlightContains`).
    private static let spotlightFallbackExtensions: Set<String> = [
        "xls", "ppt", "pages", "numbers", "key", "odt", "ods", "odp", "epub",
    ]

    /// Runs the ordered extraction pipeline for `path`, dispatching on the file
    /// extension. Always returns a result; unsupported or empty files yield
    /// `text: nil` with `strategy: .none`.
    public static func extract(path: String) -> ContentExtraction {
        let ext = (path as NSString).pathExtension.lowercased()
        let size = fileSize(path)

        if plainTextExtensions.contains(ext) {
            return extractPlainText(path: path, size: size)
        }
        switch ext {
        case "pdf":
            return extractPDF(path: path, size: size)
        case "rtf":
            return extractAttributed(path: path, documentType: .rtf, strategy: .rtf)
        case "rtfd":
            return extractAttributed(path: path, documentType: .rtfd, strategy: .rtf)
        case "doc", "docx":
            let type: NSAttributedString.DocumentType = ext == "docx" ? .officeOpenXML : .docFormat
            return extractAttributed(path: path, documentType: type, strategy: .officeDocument)
        case "xlsx":
            return extractXLSX(path: path, size: size)
        case "pptx":
            return extractPPTX(path: path, size: size)
        default:
            if imageExtensions.contains(ext) {
                return extractImageOCR(path: path, size: size)
            }
            if spotlightFallbackExtensions.contains(ext) {
                // No in-process extractor; the evaluator may still try a
                // Spotlight "contains" search. Report that so the Dry Run is honest.
                return ContentExtraction(text: nil, strategy: .none, message: "Only Spotlight ‘contains’ matching is available for this format.")
            }
            // Final fallback: lots of files are plain text with an extension we
            // don't list (e.g. .ini, .conf, .toml) or no extension at all. Try
            // to read them as text, but reject anything that looks binary.
            return extractTextFallback(path: path, size: size)
        }
    }

    /// Last-resort plain-text read for unrecognized extensions. Accepts the file
    /// only if it decodes as valid UTF-8 and contains no NUL bytes — both strong
    /// signals that it's text, not binary — so a negative operator never matches
    /// on binary content that merely happened to be readable.
    private static func extractTextFallback(path: String, size: UInt64) -> ContentExtraction {
        if size > plainTextMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "File exceeds the 50 MB text limit.")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.contains(0x00),
              let text = String(data: data, encoding: .utf8) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Unsupported file type.")
        }
        return ContentExtraction(text: text, strategy: .plainText)
    }

    // MARK: - Spotlight fallback

    /// Whether Spotlight's index should be consulted for this file when
    /// in-process extraction yields nothing. Spotlight can only answer the
    /// `contains` operator, so the evaluator gates on that.
    static func supportsSpotlightFallback(path: String) -> Bool {
        spotlightFallbackExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Builds the `mdfind` query that asks whether `name`'s indexed text
    /// contains `term` (case- and diacritic-insensitive). Factored out so the
    /// query construction and escaping can be unit-tested without the index.
    static func spotlightContainsQuery(name: String, term: String) -> String {
        "(kMDItemTextContent == \"*\(spotlightEscape(term))*\"cd) && (kMDItemFSName == \"\(spotlightEscape(name))\"cd)"
    }

    private static func spotlightEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Asks Spotlight whether the file's indexed text contains `term`. Returns
    /// false when the file isn't indexed or `mdfind` is unavailable, so it is
    /// only ever used to *confirm* a `contains` match — never to satisfy a
    /// negative operator on content we couldn't actually read.
    static func spotlightContains(path: String, term: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", url.deletingLastPathComponent().path,
                             spotlightContainsQuery(name: url.lastPathComponent, term: term)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        let target = (path as NSString).standardizingPath
        return out.split(separator: "\n").contains { ($0 as NSString).standardizingPath == target }
    }

    // MARK: - Plain text

    private static func extractPlainText(path: String, size: UInt64) -> ContentExtraction {
        if size > plainTextMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "File exceeds the 50 MB text limit.")
        }
        // UTF-8 first, then fall back to UTF-16 and ISO Latin 1 so files saved
        // with another encoding still match.
        for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
            if let text = try? String(contentsOfFile: path, encoding: encoding) {
                return ContentExtraction(text: text, strategy: .plainText)
            }
        }
        return ContentExtraction(text: nil, strategy: .none, message: "Could not decode text.")
    }

    // MARK: - PDF

    private static func extractPDF(path: String, size: UInt64) -> ContentExtraction {
        if size > pdfMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "PDF exceeds the 100 MB limit.")
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Could not open PDF.")
        }
        let pageCount = min(doc.pageCount, pdfMaxPages)
        var parts: [String] = []
        for index in 0..<pageCount {
            if let page = doc.page(at: index), let text = page.string {
                parts.append(text)
            }
        }
        let text = parts.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // No text layer — likely a scanned PDF. PDF OCR is Phase 2.
            return ContentExtraction(text: nil, strategy: .none, message: "PDF has no readable text layer.")
        }
        return ContentExtraction(text: text, strategy: .pdfText)
    }

    // MARK: - AppKit documents (RTF / Word)

    private static func extractAttributed(path: String, documentType: NSAttributedString.DocumentType, strategy: ContentStrategy) -> ContentExtraction {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        guard let attributed = try? NSAttributedString(url: URL(fileURLWithPath: path), options: options, documentAttributes: nil) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Could not read document.")
        }
        let text = attributed.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ContentExtraction(text: nil, strategy: .none, message: "Document has no readable text.")
        }
        return ContentExtraction(text: text, strategy: strategy)
    }

    // MARK: - Office Open XML (.xlsx / .pptx)

    /// `.xlsx` is a zip of XML parts. Text lives in the shared-string table
    /// (`xl/sharedStrings.xml`) and, for numbers and inline values, in the
    /// per-sheet XML.
    private static func extractXLSX(path: String, size: UInt64) -> ContentExtraction {
        if size > officeZipMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "Spreadsheet exceeds the 100 MB limit.")
        }
        guard let xml = zipText(path: path, matching: { member in
            member == "xl/sharedStrings.xml" || (member.hasPrefix("xl/worksheets/") && member.hasSuffix(".xml"))
        }) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Could not read spreadsheet.")
        }
        let text = strippedXMLText(xml)
        if text.isEmpty {
            return ContentExtraction(text: nil, strategy: .none, message: "Spreadsheet has no readable text.")
        }
        return ContentExtraction(text: text, strategy: .xlsx)
    }

    /// `.pptx` is a zip of XML parts; the slide text lives in
    /// `ppt/slides/slideN.xml`.
    private static func extractPPTX(path: String, size: UInt64) -> ContentExtraction {
        if size > officeZipMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "Presentation exceeds the 100 MB limit.")
        }
        guard let xml = zipText(path: path, matching: { member in
            member.hasPrefix("ppt/slides/slide") && member.hasSuffix(".xml")
        }) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Could not read presentation.")
        }
        let text = strippedXMLText(xml)
        if text.isEmpty {
            return ContentExtraction(text: nil, strategy: .none, message: "Presentation has no readable text.")
        }
        return ContentExtraction(text: text, strategy: .pptx)
    }

    /// Reads and concatenates the contents of every archive member whose path
    /// satisfies `matching`, decoded as UTF-8. In-process via ZIPFoundation —
    /// no subprocess. Returns `nil` when the archive can't be opened or no
    /// matching member yields data.
    private static func zipText(path: String, matching: (String) -> Bool) -> String? {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else { return nil }
        var combined = Data()
        for entry in archive where matching(entry.path) {
            var data = Data()
            guard (try? archive.extract(entry, skipCRC32: true, consumer: { data.append($0) })) != nil else { continue }
            combined.append(data)
            combined.append(0x0a) // separate members with a newline
        }
        guard !combined.isEmpty else { return nil }
        return String(data: combined, encoding: .utf8)
    }

    /// Collapses an XML fragment to readable text: drops tags, decodes the
    /// common entities, and squeezes whitespace.
    private static func strippedXMLText(_ xml: String) -> String {
        var text = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Image OCR

    private static func extractImageOCR(path: String, size: UInt64) -> ContentExtraction {
        if size > ocrImageMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "Image exceeds the 25 MB OCR limit.")
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Could not open image.")
        }
        if cgImage.width > ocrMaxDimension || cgImage.height > ocrMaxDimension {
            return ContentExtraction(text: nil, strategy: .none, message: "Image is too large for OCR.")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else {
            return ContentExtraction(text: nil, strategy: .none, message: "OCR is unavailable.")
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ContentExtraction(text: nil, strategy: .none, message: "No text found in image.")
        }
        return ContentExtraction(text: text, strategy: .imageOCR)
    }

    // MARK: - Helpers

    private static func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? UInt64) ?? 0
    }
}
