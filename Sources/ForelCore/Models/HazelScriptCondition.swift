import Foundation

public struct HazelScriptCondition: Codable, Equatable, Sendable {
    public enum Language: String, Codable, CaseIterable, Sendable { case shell, appleScript, javaScript }
    public var language: Language
    public var source: String
    public var interpreter: String
    public var externalPath: String?
    public var inputNames: [String]
    public var outputNames: [String]
    /// Base64-encoded compiled OSA script, when the export contains no source.
    public var compiledData: String?
    /// Source contains a complete hazelMatchFile handler, rather than a body.
    public var sourceIsHandler: Bool?

    public init(language: Language = .shell, source: String = "", interpreter: String = "/bin/bash", externalPath: String? = nil,
                inputNames: [String] = [], outputNames: [String] = [], compiledData: String? = nil, sourceIsHandler: Bool? = nil) {
        self.language = language; self.source = source; self.interpreter = interpreter; self.externalPath = externalPath
        self.inputNames = inputNames; self.outputNames = outputNames; self.compiledData = compiledData
        self.sourceIsHandler = sourceIsHandler
    }
    public var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    public static func decode(_ value: String) -> HazelScriptCondition? {
        guard value.utf8.count <= 1_000_000, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HazelScriptCondition.self, from: data)
    }
    public var validationError: String? {
        let availableSources = [!source.isEmpty, compiledData != nil, externalPath != nil].filter { $0 }.count
        if availableSources != 1 { return "Choose exactly one embedded, compiled, or external condition script" }
        if let externalPath, (!(externalPath as NSString).isAbsolutePath || externalPath.contains("\0")) { return "Enter an absolute script path" }
        if let compiledData, Data(base64Encoded: compiledData)?.isEmpty != false { return "Compiled script data is invalid" }
        if inputNames.contains(where: \.isEmpty) || outputNames.contains(where: \.isEmpty) || Set(outputNames).count != outputNames.count {
            return "Script attribute names must be non-empty and outputs unique"
        }
        if language == .shell && (!inputNames.isEmpty || !outputNames.isEmpty) { return "Shell conditions cannot exchange script attributes" }
        if language == .shell && (!(interpreter as NSString).isAbsolutePath || interpreter.contains("\0")) { return "Enter an absolute shell interpreter path" }
        if compiledData != nil && language == .shell { return "Shell conditions cannot use compiled script data" }
        if sourceIsHandler == true && (language == .shell || compiledData != nil || externalPath != nil) { return "A complete handler must be embedded AppleScript or JavaScript source" }
        return nil
    }
}
