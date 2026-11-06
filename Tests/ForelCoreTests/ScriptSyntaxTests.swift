import Foundation
import Testing
@testable import ForelCore

@Suite struct ScriptSyntaxTests {
    @Test func validMultilineScriptsHaveNoError() {
        let script = """
        # Move PDFs into a dated folder
        dest="$HOME/Archive/$(date +%Y)"
        if [ -f "$FOREL_FILE" ]; then
            mkdir -p "$dest"
        fi
        """
        #expect(ScriptSyntax.error(in: script) == nil)
        #expect(ScriptSyntax.error(in: "   \n") == nil)
    }

    @Test func reportsTheLineOfASyntaxError() throws {
        let message = try #require(ScriptSyntax.error(in: "echo start\nif true; then\n  echo x\n"))
        #expect(message.contains("syntax error"))
        #expect(!message.hasPrefix("bash"))
    }

    @Test func checkingNeverRunsTheScript() {
        let marker = NSTemporaryDirectory() + "forel-syntax-\(UUID().uuidString)"
        #expect(ScriptSyntax.error(in: "touch \"\(marker)\"\n") == nil)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}
