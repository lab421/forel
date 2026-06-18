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

/// How a file's text was obtained. Drives the Dry Run's per-condition detail.
/// Cases marked Phase 2 are reserved so the display and call sites don't need to
/// change when those extractors are added.
public enum ContentStrategy: String, Sendable {
    case plainText
    case pdfText
    case pdfOCR          // Phase 2 (scanned PDFs)
    case rtf
    case officeDocument  // .doc / .docx via AppKit
    case xlsx            // Phase 2
    case pptx            // Phase 2
    case iWork           // Phase 2
    case officeLegacy    // Phase 2
    case spotlight       // Phase 2
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

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "csv", "tsv", "json", "xml", "yaml", "yml", "html", "css",
        "js", "ts", "swift", "rs", "py", "rb", "go", "java", "c", "cpp", "h", "log",
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "tif",
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
        default:
            if imageExtensions.contains(ext) {
                return extractImageOCR(path: path, size: size)
            }
            return ContentExtraction(text: nil, strategy: .none, message: "Unsupported file type.")
        }
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
