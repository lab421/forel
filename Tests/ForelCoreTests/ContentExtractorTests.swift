// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

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

    @Test func scannedPdfFallsBackToOCR() throws {
        let dir = TempDir()
        let pdf = (dir.path as NSString).appendingPathComponent("scanned.pdf")
        makeScannedPDF(at: pdf, text: "SCANNED INVOICE 2026")

        let result = ContentExtractor.extract(path: pdf)
        // OCR may be unavailable in some headless environments; only assert the
        // match when recognition actually produced text.
        if result.text != nil {
            #expect(result.strategy == .pdfOCR)
            #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "SCANNED"), path: pdf))
        }
    }

    @Test(arguments: [false, true])
    func textPDFRunsInBothPlansAcrossPreviewManualAndWatcher(isPro: Bool) throws {
        let dir = TempDir()
        let file = dir.path + "/invoice.pdf"
        makeTextPDF(at: file, text: "Invoice total 1234 EUR")
        #expect(ContentExtractor.extract(path: file, allowOCR: isPro).strategy == .pdfText)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Invoice")
        rule.conditions = [makeCondition(.contents, .contains, "1234", ruleId: rule.id)]
        rule.actions = [makeAction(.rename, .object(["pattern": .string("sorted.pdf")]), ruleId: rule.id)]
        try db.insertRule(rule, isPro: isPro)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], isPro: isPro) != nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "manual", isPro: isPro).history.first?.status == .applied)
        makeTextPDF(at: file, text: "Invoice total 1234 EUR")
        try FileManager.default.removeItem(atPath: dir.path + "/sorted.pdf")
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(isPro)
        watcher.handle(path: file)
        #expect(try db.listHistory().first?.status == .applied)
    }

    @Test(arguments: ["image", "scan"])
    func freeNeverRunsOCROrMatchesNegativeContentsAcrossAllPaths(kind: String) throws {
        let dir = TempDir()
        let file = dir.path + (kind == "image" ? "/invoice.png" : "/invoice.pdf")
        if kind == "image" { makeTextImage(at: file, text: "INVOICE 2026") }
        else { makeScannedPDF(at: file, text: "INVOICE 2026") }
        let extraction = ContentExtractor.extract(path: file, allowOCR: false)
        #expect(extraction.text == nil)
        #expect(extraction.message?.contains("Pro") == true)
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "Contents")
        rule.actions = [makeAction(.rename, .object(["pattern": .string("sorted.dat")]), ruleId: rule.id)]
        for op in [Operator.contains, .doesNotContain, .isNot] {
            rule.conditions = [makeCondition(.contents, op, "INVOICE", ruleId: rule.id)]
            #expect(!ConditionEvaluator.evaluate(rule.conditions[0], path: file, allowOCR: false))
            #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], isPro: false) == nil)
            #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "free", isPro: false).history.isEmpty)
        }
        try db.insertRule(rule, isPro: false)
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(false)
        watcher.handle(path: file)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(try db.listHistory().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test(arguments: ["image", "scan"])
    func proOCRIsConsistentAcrossPreviewManualRunAndWatcher(kind: String) throws {
        let dir = TempDir()
        let ext = kind == "image" ? "png" : "pdf"
        let file = dir.path + "/invoice.\(ext)"
        func createFile() {
            if kind == "image" { makeTextImage(at: file, text: "INVOICE 2026") }
            else { makeScannedPDF(at: file, text: "INVOICE 2026") }
        }
        createFile()
        // Some CI hosts cannot run Vision. When available, verify all paths.
        guard ContentExtractor.extract(path: file).text != nil else { return }
        let db = try Database(path: ":memory:")
        let folder = WatchedFolder(path: dir.path)
        try db.insertFolder(folder)
        var rule = makeRule(folderId: folder.id, name: "OCR invoice")
        rule.conditions = [makeCondition(.contents, .contains, "INVOICE", ruleId: rule.id)]
        rule.actions = [makeAction(.rename, .object(["pattern": .string("sorted.\(ext)")]), ruleId: rule.id)]
        try db.insertRule(rule, isPro: true)
        #expect(RuleEngine.previewFile(path: file, depth: 0, rules: [rule], isPro: true) != nil)
        #expect(RuleEngine.run(path: file, depth: 0, rules: [rule], batchId: "manual", isPro: true).history.first?.status == .applied)
        try FileManager.default.removeItem(atPath: dir.path + "/sorted.\(ext)")
        createFile()
        let watcher = WatcherCoordinator(db: db)
        watcher.setProAccess(true)
        watcher.handle(event: .rescanSubtree(dir.path))
        #expect(try db.listHistory().first?.status == .applied)
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

    @Test func xlsxSharedStringsAreExtracted() throws {
        let dir = TempDir()
        let xlsx = makeXLSX(in: dir, sharedStrings: ["Quarterly Revenue", "Paris office"])

        let result = ContentExtractor.extract(path: xlsx)
        #expect(result.strategy == .xlsx)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Revenue"), path: xlsx))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Paris office"), path: xlsx))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Berlin"), path: xlsx))
    }

    @Test func pptxSlideTextIsExtracted() throws {
        let dir = TempDir()
        let pptx = makePPTX(in: dir, slides: ["Roadmap 2026", "Launch in Berlin"])

        let result = ContentExtractor.extract(path: pptx)
        #expect(result.strategy == .pptx)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Roadmap"), path: pptx))
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Berlin"), path: pptx))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Tokyo"), path: pptx))
    }

    @Test func openDocumentTextIsExtracted() throws {
        let dir = TempDir()
        let odt = makeOpenDocument(in: dir, name: "notes.odt", text: "Hello OpenDocument world")

        let result = ContentExtractor.extract(path: odt)
        #expect(result.strategy == .openDocument)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "OpenDocument"), path: odt))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Microsoft"), path: odt))
    }

    @Test func openDocumentSpreadsheetIsExtracted() throws {
        let dir = TempDir()
        let ods = makeOpenDocument(in: dir, name: "budget.ods", text: "Revenue 4242 EUR")

        let result = ContentExtractor.extract(path: ods)
        #expect(result.strategy == .openDocument)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "4242"), path: ods))
    }

    @Test func iWorkFlatFileReadsPreviewPDF() throws {
        let dir = TempDir()
        let pages = makeIWorkFlatFile(in: dir, name: "proposal.pages", previewText: "Project proposal for Acme")

        let result = ContentExtractor.extract(path: pages)
        #expect(result.strategy == .iWork)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "proposal for Acme"), path: pages))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "invoice"), path: pages))
    }

    @Test func iWorkPackageReadsPreviewPDF() throws {
        let dir = TempDir()
        let numbers = makeIWorkPackage(in: dir, name: "budget.numbers", previewText: "Budget Q3 totals 12345")

        let result = ContentExtractor.extract(path: numbers)
        #expect(result.strategy == .iWork)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Budget Q3"), path: numbers))
    }

    @Test func iWorkWithoutPreviewReturnsNone() throws {
        let dir = TempDir()
        // A flat-file iWork doc with no QuickLook/Preview.pdf member.
        let staging = dir.dir("nopreview-staging")
        let dataDir = (staging as NSString).appendingPathComponent("Data")
        try! FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try "binary-ish".write(toFile: (dataDir as NSString).appendingPathComponent("Index.iwa"), atomically: true, encoding: .utf8)
        let key = (dir.path as NSString).appendingPathComponent("deck.key")
        zipStaging(staging, topLevel: "Data", into: key)

        #expect(ContentExtractor.extract(path: key).strategy == .none)
    }

    @Test func corruptSpreadsheetReturnsNoContentWithoutCrashing() throws {
        let dir = TempDir()
        let xlsx = (dir.path as NSString).appendingPathComponent("broken.xlsx")
        try Data([0x50, 0x4b, 0x03, 0x04, 0x00]).write(to: URL(fileURLWithPath: xlsx))

        let result = ContentExtractor.extract(path: xlsx)
        #expect(result.text == nil)
        #expect(result.strategy == .none)
    }

    @Test func corruptDocumentReturnsNoContentWithoutCrashing() throws {
        let dir = TempDir()
        let docx = (dir.path as NSString).appendingPathComponent("broken.docx")
        try Data([0x50, 0x4b, 0x03, 0x04, 0x00, 0x00]).write(to: URL(fileURLWithPath: docx))

        let result = ContentExtractor.extract(path: docx)
        #expect(result.text == nil)
        #expect(result.strategy == .none)
    }

    @Test func spotlightFallbackGatingAndQueryBuilding() throws {
        #expect(ContentExtractor.supportsSpotlightFallback(path: "/tmp/book.xls"))
        #expect(ContentExtractor.supportsSpotlightFallback(path: "/tmp/deck.key"))
        #expect(!ContentExtractor.supportsSpotlightFallback(path: "/tmp/notes.txt"))
        #expect(!ContentExtractor.supportsSpotlightFallback(path: "/tmp/archive.zip"))

        let query = ContentExtractor.spotlightContainsQuery(name: "book.xls", term: "Re\"ve\\nue")
        // Quotes and backslashes in the term must be escaped so the query stays valid.
        #expect(query == #"(kMDItemTextContent == "*Re\"ve\\nue*"cd) && (kMDItemFSName == "book.xls"cd)"#)
    }

    @Test func legacyXlsOnlyUsesSpotlightForContains() throws {
        let dir = TempDir()
        let xls = (dir.path as NSString).appendingPathComponent("ledger.xls")
        try Data([0xd0, 0xcf, 0x11, 0xe0]).write(to: URL(fileURLWithPath: xls)) // OLE2 magic

        // A temp file isn't in the Spotlight index, and only `contains` is even
        // attempted — every other operator must report no readable content.
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .is, "anything"), path: xls))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .matchesRegex, ".*"), path: xls))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .doesNotContain, "x"), path: xls))
        #expect(ContentExtractor.extract(path: xls).strategy == .none)
    }

    @Test func unknownExtensionFallsBackToPlainTextWhenTextual() throws {
        let dir = TempDir()
        // An extension we don't list, but the content is plain text.
        let conf = dir.file("settings.conf", contents: "host = localhost\nport = 8080")
        let result = ContentExtractor.extract(path: conf)
        #expect(result.strategy == .plainText)
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "localhost"), path: conf))

        // A file with no extension at all, also textual.
        let noExt = dir.file("LICENSE", contents: "Permission is hereby granted")
        #expect(ConditionEvaluator.evaluate(makeCondition(.contents, .contains, "Permission"), path: noExt))
    }

    @Test func unknownExtensionWithBinaryContentReturnsNone() throws {
        let dir = TempDir()
        // NUL byte + invalid UTF-8: must be treated as binary, never matched.
        let blob = (dir.path as NSString).appendingPathComponent("data.xyz")
        try Data([0x00, 0x01, 0x02, 0xff, 0xfe]).write(to: URL(fileURLWithPath: blob))

        let result = ContentExtractor.extract(path: blob)
        #expect(result.text == nil)
        #expect(result.strategy == .none)
        #expect(!ConditionEvaluator.evaluate(makeCondition(.contents, .doesNotContain, "x"), path: blob))
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

/// Renders `text` as large black-on-white text into an image (no text layer).
private func renderTextImage(_ text: String, size: NSSize = NSSize(width: 600, height: 200)) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(
        at: CGPoint(x: 40, y: size.height / 2 - 30),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black]
    )
    image.unlockFocus()
    return image
}

private func makeTextImage(at path: String, text: String) {
    writePNG(renderTextImage(text), to: path)
}

/// Builds a single-page PDF whose page is an *image* of the text — i.e. no text
/// layer, like a scan — so extraction must fall back to OCR.
private func makeScannedPDF(at path: String, text: String) {
    let image = renderTextImage(text, size: NSSize(width: 1000, height: 300))
    guard let page = PDFPage(image: image) else { return }
    let doc = PDFDocument()
    doc.insert(page, at: 0)
    doc.write(to: URL(fileURLWithPath: path))
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

/// Builds a minimal valid `.xlsx` (a zip with `xl/sharedStrings.xml`) by writing
/// the part and zipping it with `/usr/bin/zip`.
private func makeXLSX(in dir: TempDir, sharedStrings: [String]) -> String {
    let staging = dir.dir("xlsx-staging")
    let xlDir = (staging as NSString).appendingPathComponent("xl")
    try! FileManager.default.createDirectory(atPath: xlDir, withIntermediateDirectories: true)

    let items = sharedStrings.map { "<si><t>\($0)</t></si>" }.joined()
    let xml = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">\(items)</sst>
    """
    try! xml.write(toFile: (xlDir as NSString).appendingPathComponent("sharedStrings.xml"), atomically: true, encoding: .utf8)

    let xlsx = (dir.path as NSString).appendingPathComponent("report.xlsx")
    zipStaging(staging, topLevel: "xl", into: xlsx)
    return xlsx
}

/// Zips `topLevel` (relative to `staging`) into the archive at `destination`.
private func zipStaging(_ staging: String, topLevel: String, into destination: String) {
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = URL(fileURLWithPath: staging)
    zip.arguments = ["-r", "-q", destination, topLevel]
    zip.standardError = FileHandle.nullDevice
    try! zip.run()
    zip.waitUntilExit()
}

/// Builds a minimal valid `.pptx` (a zip with one `ppt/slides/slideN.xml` per
/// slide) by writing the parts and zipping them with `/usr/bin/zip`.
private func makePPTX(in dir: TempDir, slides: [String]) -> String {
    let staging = dir.dir("pptx-staging")
    let slidesDir = (staging as NSString).appendingPathComponent("ppt/slides")
    try! FileManager.default.createDirectory(atPath: slidesDir, withIntermediateDirectories: true)

    for (index, text) in slides.enumerated() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:t>\(text)</a:t></p:sld>
        """
        try! xml.write(toFile: (slidesDir as NSString).appendingPathComponent("slide\(index + 1).xml"), atomically: true, encoding: .utf8)
    }

    let pptx = (dir.path as NSString).appendingPathComponent("deck.pptx")
    zipStaging(staging, topLevel: "ppt", into: pptx)
    return pptx
}

/// Builds an OpenDocument file (a zip with a `content.xml` body part).
private func makeOpenDocument(in dir: TempDir, name: String, text: String) -> String {
    let staging = dir.dir("odf-staging-\(name)")
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
    <office:body><office:text><text:p>\(text)</text:p></office:text></office:body>
    </office:document-content>
    """
    try! xml.write(toFile: (staging as NSString).appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)

    let doc = (dir.path as NSString).appendingPathComponent(name)
    zipStaging(staging, topLevel: "content.xml", into: doc)
    return doc
}

/// Builds a flat-file (zip) iWork document containing `QuickLook/Preview.pdf`.
private func makeIWorkFlatFile(in dir: TempDir, name: String, previewText: String) -> String {
    let staging = dir.dir("iwork-flat-staging")
    let qlDir = (staging as NSString).appendingPathComponent("QuickLook")
    try! FileManager.default.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
    makeTextPDF(at: (qlDir as NSString).appendingPathComponent("Preview.pdf"), text: previewText)

    let doc = (dir.path as NSString).appendingPathComponent(name)
    zipStaging(staging, topLevel: "QuickLook", into: doc)
    return doc
}

/// Builds a package (directory) iWork document containing QuickLook/Preview.pdf.
private func makeIWorkPackage(in dir: TempDir, name: String, previewText: String) -> String {
    let pkg = dir.dir(name)
    let qlDir = (pkg as NSString).appendingPathComponent("QuickLook")
    try! FileManager.default.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
    makeTextPDF(at: (qlDir as NSString).appendingPathComponent("Preview.pdf"), text: previewText)
    return pkg
}

private func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}
