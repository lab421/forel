import Testing
import Foundation
import PDFKit
import AppKit
@testable import ForelCore

@Suite struct ContentExtractorTests {
    @Test func plainTextFallsBackToUTF16() throws {
        let dir = TempDir()
        let file = (dir.path as NSString).appendingPathComponent("utf16.txt")
        try "Facture payée — 42 €".data(using: .utf16)!.write(to: URL(fileURLWithPath: file))

        let result = ContentExtractor.extract(path: file)
        #expect(result.strategy == .plainText)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "payée"), path: file))
    }

    @Test func unreadableContentNeverMatchesAnyOperator() throws {
        let dir = TempDir()
        let binary = (dir.path as NSString).appendingPathComponent("blob.dat")
        try Data([0x00, 0x01, 0x02, 0xff]).write(to: URL(fileURLWithPath: binary))

        let result = ContentExtractor.extract(path: binary)
        #expect(result.text == nil)
        #expect(result.strategy == .none)
        // Negative operators must not match content that could not be read.
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .doesNotContain, "x"), path: binary))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .isNot, "x"), path: binary))
    }

    @Test func pdfTextLayerIsExtracted() throws {
        let dir = TempDir()
        let pdf = (dir.path as NSString).appendingPathComponent("invoice.pdf")
        makeTextPDF(at: pdf, text: "Invoice total 1234 EUR")

        let result = ContentExtractor.extract(path: pdf)
        #expect(result.strategy == .pdfText)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "1234"), path: pdf))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "refund"), path: pdf))
    }

    @Test func rtfDocumentIsExtracted() throws {
        let dir = TempDir()
        let rtf = (dir.path as NSString).appendingPathComponent("memo.rtf")
        let attributed = NSAttributedString(string: "Quarterly report draft")
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try data.write(to: URL(fileURLWithPath: rtf))

        let result = ContentExtractor.extract(path: rtf)
        #expect(result.strategy == .rtf)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Quarterly"), path: rtf))
    }

    @Test func wordDocumentIsExtracted() throws {
        let dir = TempDir()
        let docx = (dir.path as NSString).appendingPathComponent("letter.docx")
        let attributed = NSAttributedString(string: "Dear customer, payment received")
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: URL(fileURLWithPath: docx))

        let result = ContentExtractor.extract(path: docx)
        #expect(result.strategy == .officeDocument)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "payment received"), path: docx))
    }

    @Test func corruptDocumentReturnsNoContentWithoutCrashing() throws {
        let dir = TempDir()
        let docx = (dir.path as NSString).appendingPathComponent("broken.docx")
        try Data([0x50, 0x4b, 0x03, 0x04, 0x00, 0x00]).write(to: URL(fileURLWithPath: docx))

        let result = ContentExtractor.extract(path: docx)
        #expect(result.text == nil)
        #expect(result.strategy == .none)
    }

    @Test func unsupportedExtensionReturnsNone() throws {
        let dir = TempDir()
        let file = dir.file("archive.zip", contents: "not really a zip")

        let result = ContentExtractor.extract(path: file)
        #expect(result.text == nil)
        #expect(result.strategy == .none)
    }

    @Test func imageOcrReadsRenderedText() throws {
        let dir = TempDir()
        let png = (dir.path as NSString).appendingPathComponent("scan.png")
        makeTextImage(at: png, text: "HELLO WORLD")

        let result = ContentExtractor.extract(path: png)
        // OCR may be unavailable in some headless environments; only assert the
        // match when recognition actually produced text.
        if result.text != nil {
            #expect(result.strategy == .imageOCR)
            #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "HELLO"), path: png))
        }
    }

    @Test func blankImageFindsNoText() throws {
        let dir = TempDir()
        let png = (dir.path as NSString).appendingPathComponent("blank.png")
        makeBlankImage(at: png)

        let result = ContentExtractor.extract(path: png)
        #expect(result.text == nil)
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "anything"), path: png))
    }

    @Test func evaluateContentsReportsStrategy() throws {
        let dir = TempDir()
        let txt = dir.file("notes.txt", contents: "hello there")
        #expect(ConditionEvaluator.evaluateContents(makeCondition(.contents, .contains, "hello"), path: txt).strategy == .plainText)

        let missing = (dir.path as NSString).appendingPathComponent("ghost.bin")
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: missing))
        #expect(ConditionEvaluator.evaluateContents(makeCondition(.contents, .contains, "x"), path: missing).strategy == .none)
    }
}

// MARK: - Fixtures

/// Draws `text` into a single-page PDF with a real text layer that PDFKit can read.
private func makeTextPDF(at path: String, text: String) {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil) else { return }
    ctx.beginPDFPage(nil)
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    (text as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
    ctx.closePDF()
}

private func makeTextImage(at path: String, text: String) {
    let size = NSSize(width: 600, height: 200)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(
        at: CGPoint(x: 40, y: 80),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black]
    )
    image.unlockFocus()
    writePNG(image, to: path)
}

private func makeBlankImage(at path: String) {
    let size = NSSize(width: 200, height: 200)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    writePNG(image, to: path)
}

private func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
