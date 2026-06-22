import Testing
@testable import ForelCore

@Suite struct SystemFileFilterTests {
    @Test func excludesKnownNoisySystemFiles() {
        #expect(SystemFileFilter.isExcluded(".DS_Store"))
        #expect(SystemFileFilter.isExcluded("._report.pdf")) // AppleDouble resource fork
        #expect(SystemFileFilter.isExcluded("~$budget.docx")) // Office lock file
    }

    @Test func doesNotExcludeRegularFiles() {
        #expect(!SystemFileFilter.isExcluded("report.pdf"))
        #expect(!SystemFileFilter.isExcluded("budget.docx"))
        #expect(!SystemFileFilter.isExcluded("invoice_march_2026.pdf"))
    }
}
