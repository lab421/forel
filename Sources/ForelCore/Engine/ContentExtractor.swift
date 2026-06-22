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
public enum ContentStrategy: String, Sendable {
    case plainText
    case pdfText
    case pdfOCR
    case rtf
    case officeDocument  // .doc / .docx via AppKit
    case xlsx
    case pptx
    case openDocument    // .odt / .ods / .odp
    case iWork
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
        case .openDocument: return "OpenDocument"
        case .iWork: return "iWork document"
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
    private static let plainTextMaxBytes: UInt64 = 100 * 1024 * 1024
    private static let pdfMaxBytes: UInt64 = 100 * 1024 * 1024
    private static let pdfMaxPages = 100
    private static let pdfOCRMaxPages = 20
    private static let pdfOCRRenderScale: CGFloat = 2.0
    private static let ocrImageMaxBytes: UInt64 = 25 * 1024 * 1024
    private static let ocrMaxDimension = 12_000
    private static let defaultMaxBytes: UInt64 = 100 * 1024 * 1024

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "json", "xml", "yaml", "yml", "html", "css",
        "js", "ts", "swift", "rs", "py", "rb", "go", "java", "c", "cpp", "h", "log",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif",
        "webp", "gif", "bmp", "jp2", "j2k", "psd",
    ]
    /// Formats with no in-process text extractor that macOS can still index.
    /// For these we fall back to a Spotlight search, which only answers the
    /// `contains` operator (see `spotlightContains`).
    private static let spotlightFallbackExtensions: Set<String> = [
        "xls", "ppt", "pages", "numbers", "key", "epub",
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
        case "doc", "docx", "dotx":
            let type: NSAttributedString.DocumentType = (ext == "docx" || ext == "dotx") ? .officeOpenXML : .docFormat
            return extractAttributed(path: path, documentType: type, strategy: .officeDocument)
        case "xlsx", "xltx":
            return extractXLSX(path: path, size: size)
        case "pptx", "potx":
            return extractPPTX(path: path, size: size)
        case "odt", "ods", "odp":
            return extractOpenDocument(path: path, size: size)
        case "pages", "numbers", "key":
            return extractIWork(path: path, size: size)
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
            return ContentExtraction(text: nil, strategy: .none, message: "File exceeds the 100 MB text limit.")
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
    /// negative operator on content we couldn't actually read. Times out after
    /// 15 seconds to avoid hanging on an unresponsive Spotlight index.
    static func spotlightContains(path: String, term: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", url.deletingLastPathComponent().path,
                             spotlightContainsQuery(name: url.lastPathComponent, term: term)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        guard semaphore.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        let target = (path as NSString).standardizingPath
        return out.split(separator: "\n").contains { ($0 as NSString).standardizingPath == target }
    }

    // MARK: - Plain text

    private static func extractPlainText(path: String, size: UInt64) -> ContentExtraction {
        if size > plainTextMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "File exceeds the 100 MB text limit.")
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
        let text = pdfText(from: doc)
        if !text.isEmpty {
            return ContentExtraction(text: text, strategy: .pdfText)
        }
        // No text layer — likely a scanned PDF. OCR the rendered pages.
        let ocr = pdfOCRText(from: doc)
        if !ocr.isEmpty {
            return ContentExtraction(text: ocr, strategy: .pdfOCR)
        }
        return ContentExtraction(text: nil, strategy: .none, message: "PDF has no readable text.")
    }

    /// Concatenates the text layer of a PDF document, up to the page limit.
    private static func pdfText(from doc: PDFDocument) -> String {
        let pageCount = min(doc.pageCount, pdfMaxPages)
        var parts: [String] = []
        for index in 0..<pageCount {
            if let page = doc.page(at: index), let text = page.string {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OCRs a scanned PDF by rendering each page to a bitmap and running Vision,
    /// up to a tighter page limit since this is far more expensive than reading
    /// a text layer.
    private static func pdfOCRText(from doc: PDFDocument) -> String {
        let pageCount = min(doc.pageCount, pdfOCRMaxPages)
        var parts: [String] = []
        for index in 0..<pageCount {
            guard let page = doc.page(at: index),
                  let cgImage = renderPDFPage(page),
                  let text = recognizeText(in: cgImage) else { continue }
            parts.append(text)
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renders a PDF page to a bitmap `CGImage` for OCR, scaled up for accuracy.
    private static func renderPDFPage(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * pdfOCRRenderScale)
        let height = Int(bounds.height * pdfOCRRenderScale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // White background so OCR sees dark-on-light text.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: pdfOCRRenderScale, y: pdfOCRRenderScale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - AppKit documents (RTF / Word)

    private static func extractAttributed(path: String, documentType: NSAttributedString.DocumentType, strategy: ContentStrategy) -> ContentExtraction {
        if fileSize(path) > defaultMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "Document exceeds the 100 MB limit.")
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
        guard let attributed = attributedString(url: URL(fileURLWithPath: path), options: options) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Could not read document.")
        }
        let text = attributed.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ContentExtraction(text: nil, strategy: .none, message: "Document has no readable text.")
        }
        return ContentExtraction(text: text, strategy: strategy)
    }

    /// Builds an `NSAttributedString` from a document, always on the main thread.
    /// The AppKit document importers for Word/RTF are not safe to call off the
    /// main thread, and content extraction runs on a background queue (watcher)
    /// or a detached task (Run Now / Dry Run) — so hop to the main thread for
    /// this step. The `Thread.isMainThread` guard avoids deadlocking if a caller
    /// is ever already on the main thread.
    private static func attributedString(url: URL, options: [NSAttributedString.DocumentReadingOptionKey: Any]) -> NSAttributedString? {
        func make() -> NSAttributedString? {
            try? NSAttributedString(url: url, options: options, documentAttributes: nil)
        }
        if Thread.isMainThread {
            return make()
        }
        // main queue can't deadlock on itself because of the guard above.
        return DispatchQueue.main.sync(execute: make)
    }

    // MARK: - Office Open XML (.xlsx / .pptx)

    /// `.xlsx` is a zip of XML parts. Text lives in the shared-string table
    /// (`xl/sharedStrings.xml`) and, for numbers and inline values, in the
    /// per-sheet XML.
    private static func extractXLSX(path: String, size: UInt64) -> ContentExtraction {
        if size > defaultMaxBytes {
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
        if size > defaultMaxBytes {
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

    // MARK: - OpenDocument (.odt / .ods / .odp)

    /// OpenDocument files are zip archives whose body text lives in a single,
    /// well-documented `content.xml` part. Read it and strip the markup.
    private static func extractOpenDocument(path: String, size: UInt64) -> ContentExtraction {
        if size > defaultMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "Document exceeds the 100 MB limit.")
        }
        guard let xml = zipText(path: path, matching: { $0 == "content.xml" }) else {
            return ContentExtraction(text: nil, strategy: .none, message: "Could not read document.")
        }
        let text = strippedXMLText(xml)
        if text.isEmpty {
            return ContentExtraction(text: nil, strategy: .none, message: "Document has no readable text.")
        }
        return ContentExtraction(text: text, strategy: .openDocument)
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

    /// Collapses an XML fragment to readable text: strips comments, drops tags,
    /// decodes the common entities, and squeezes whitespace.
    private static func strippedXMLText(_ xml: String) -> String {
        // Strip XML comments first so `>` inside comments doesn't break the tag regex.
        var text = xml.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Apple iWork (.pages / .numbers / .key)

    /// iWork stores its real content in a proprietary binary format we can't
    /// parse, but documents almost always embed a `QuickLook/Preview.pdf` — the
    /// rendered preview — whose text layer we read with PDFKit. Handles both the
    /// flat-file (zip) and package (directory) on-disk shapes. When there's no
    /// preview, the evaluator can still fall back to Spotlight for `contains`.
    private static func extractIWork(path: String, size: UInt64) -> ContentExtraction {
        if size > defaultMaxBytes {
            return ContentExtraction(text: nil, strategy: .none, message: "iWork document exceeds the 100 MB limit.")
        }
        guard let pdfData = iWorkPreviewPDF(path: path), let doc = PDFDocument(data: pdfData) else {
            return ContentExtraction(text: nil, strategy: .none, message: "iWork preview not available.")
        }
        let text = pdfText(from: doc)
        if text.isEmpty {
            return ContentExtraction(text: nil, strategy: .none, message: "iWork preview has no readable text.")
        }
        return ContentExtraction(text: text, strategy: .iWork)
    }

    /// Returns the bytes of the document's `QuickLook/Preview.pdf`, whether the
    /// iWork file is a single zip archive or an on-disk package (directory).
    private static func iWorkPreviewPDF(path: String) -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let preview = (path as NSString).appendingPathComponent("QuickLook/Preview.pdf")
            return try? Data(contentsOf: URL(fileURLWithPath: preview))
        }
        return zipMemberData(path: path) { $0.lowercased().hasSuffix("quicklook/preview.pdf") }
    }

    /// Reads the bytes of the first archive member whose path satisfies
    /// `matching`. Used for binary members (e.g. an embedded PDF), unlike
    /// `zipText` which decodes to text.
    private static func zipMemberData(path: String, matching: (String) -> Bool) -> Data? {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read, pathEncoding: nil) else { return nil }
        for entry in archive where matching(entry.path) {
            var data = Data()
            guard (try? archive.extract(entry, skipCRC32: true, consumer: { data.append($0) })) != nil else { continue }
            if !data.isEmpty { return data }
        }
        return nil
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
        guard let text = recognizeText(in: cgImage) else {
            return ContentExtraction(text: nil, strategy: .none, message: "No text found in image.")
        }
        return ContentExtraction(text: text, strategy: .imageOCR)
    }

    /// Runs on-device Vision text recognition on a bitmap, returning the joined
    /// lines or `nil` when nothing is recognized (or OCR is unavailable). Shared
    /// by image and scanned-PDF extraction. Times out after 30 seconds to avoid
    /// hanging the caller when the Vision framework is unresponsive.
    private static func recognizeText(in cgImage: CGImage) -> String? {
        nonisolated(unsafe) let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        nonisolated(unsafe) let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let semaphore = DispatchSemaphore(value: 0)
        // Safe despite the `unsafe` in the name: the semaphore wait below
        // blocks until the background closure signals, so there's no actual
        // concurrent access — just the compiler unable to see that VNRequest
        // types aren't Sendable for a reason that applies here.
        nonisolated(unsafe) var resultText: String?
        DispatchQueue.global(qos: .userInitiated).async {
            guard (try? handler.perform([request])) != nil, let observations = request.results else {
                semaphore.signal()
                return
            }
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            resultText = text.isEmpty ? nil : text
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        return resultText
    }

    // MARK: - Helpers

    private static func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? UInt64) ?? 0
    }
}
