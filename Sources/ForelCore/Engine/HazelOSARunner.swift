// Forel - A native macOS file-automation app
// Copyright (C) 2026 Lab421
import Foundation
import Darwin

/// Runs an OSA script in a separate process. Script output is never used as
/// the control channel: the runner writes its result into a private file.
enum HazelOSARunner {
    enum Language: String { case appleScript = "AppleScript", javaScript = "JavaScript" }
    enum Purpose: String { case action, condition }
    enum Source {
        case embedded(String)
        case sourceHandler(String)
        case legacySource(String)
        case external(String)
        case compiled(Data)
        case legacyCompiled(Data)
    }
    struct Result {
        let stop: Bool
        let switchPath: String?
        let attributes: [String: JSONValue]
        let orderedAttributes: [JSONValue]
        let passes: Bool?
    }

    static func run(language: Language, source: Source, path: String, inputs: [JSONValue], purpose: Purpose = .action) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("forel-osa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL: URL
        let mode: String
        switch source {
        case .embedded(let text):
            guard text.utf8.count <= 1_000_000, !text.contains("\0") else { throw ActionError("Invalid script source") }
            sourceURL = directory.appendingPathComponent("source")
            try Data(text.utf8).write(to: sourceURL, options: .atomic)
            mode = "embedded"
        case .sourceHandler(let text), .legacySource(let text):
            guard text.utf8.count <= 1_000_000, !text.contains("\0") else { throw ActionError("Invalid script source") }
            let textURL = directory.appendingPathComponent("source.applescript")
            try Data(text.utf8).write(to: textURL, options: .atomic)
            if case .legacySource = source {
                sourceURL = directory.appendingPathComponent("source.scpt")
                let compiler = Process()
                compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
                compiler.arguments = ["-o", sourceURL.path, textURL.path]
                compiler.standardInput = FileHandle.nullDevice
                compiler.standardOutput = FileHandle.nullDevice
                compiler.standardError = FileHandle.nullDevice
                try compiler.run()
                let deadline = Date().addingTimeInterval(30)
                while compiler.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if compiler.isRunning {
                    compiler.terminate(); Thread.sleep(forTimeInterval: 0.1)
                    if compiler.isRunning { kill(compiler.processIdentifier, SIGKILL) }
                    compiler.waitUntilExit()
                    throw ActionError("Script compilation timed out")
                }
                compiler.waitUntilExit()
                guard compiler.terminationStatus == 0 else { throw ActionError("Script compilation failed") }
                mode = "legacy"
            } else {
                sourceURL = textURL
                mode = "sourceHandler"
            }
        case .compiled(let data), .legacyCompiled(let data):
            guard data.count <= 1_000_000,
                  data.starts(with: Data((language == .appleScript ? "Fasd" : "JsOsa").utf8)) else { throw ActionError("Invalid compiled script") }
            sourceURL = directory.appendingPathComponent("source.scpt")
            try data.write(to: sourceURL, options: .atomic)
            if case .legacyCompiled = source { mode = "legacy" } else { mode = "external" }
        case .external(let file):
            guard file.hasPrefix("/"), !file.contains("\0") else { throw ActionError("Script path must be absolute") }
            sourceURL = URL(fileURLWithPath: file)
            mode = "external"
        }
        let driverURL = directory.appendingPathComponent("driver.js")
        let inputURL = directory.appendingPathComponent("inputs.json")
        let outputURL = directory.appendingPathComponent("result.json")
        let errorURL = directory.appendingPathComponent("errors")
        try Data((mode == "legacy" ? legacyDriver : driver).utf8).write(to: driverURL, options: .atomic)
        try JSONEncoder().encode(inputs).write(to: inputURL, options: .atomic)
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else { throw ActionError("Cannot prepare script output") }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        if mode == "legacy" {
            process.arguments = ["-l", "AppleScript", driverURL.path, sourceURL.path, URL(fileURLWithPath: path).standardizedFileURL.path, outputURL.path]
        } else {
            process.arguments = ["-l", "JavaScript", driverURL.path, language.rawValue, mode, purpose.rawValue, sourceURL.path,
                                 URL(fileURLWithPath: path).standardizedFileURL.path, inputURL.path, outputURL.path]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let start = Date()
        while process.isRunning && Date().timeIntervalSince(start) < 60 { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ActionError("Script timed out after 60s")
        }
        process.waitUntilExit()
        try errors.close()
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: errorURL)
            defer { try? reader.close() }
            let message = String(decoding: try reader.read(upToCount: 4096) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError("Script failed\(message.isEmpty ? "" : ": \(message)")")
        }
        let output = try FileHandle(forReadingFrom: outputURL)
        defer { try? output.close() }
        let data = try output.read(upToCount: 1_000_001) ?? Data()
        guard data.count <= 1_000_000, resultWithinLimits(data),
              case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data),
              let stop = object["stop"]?.boolValue,
              case .object(let attributes) = object["attributes"],
              case .array(let orderedAttributes) = object["orderedAttributes"] else { throw ActionError("Invalid script result") }
        var count = 0
        func check(_ value: JSONValue, depth: Int) throws {
            count += 1
            guard depth <= 32, count <= 10_000 else { throw ActionError("Script result is too complex") }
            switch value {
            case .array(let values): for item in values { try check(item, depth: depth + 1) }
            case .object(let values): for item in values.values { try check(item, depth: depth + 1) }
            default: break
            }
        }
        try check(.object(attributes), depth: 0)
        let switchPath = object["switchPath"]?.stringValue
        if let switchPath, (!switchPath.hasPrefix("/") || !FileManager.default.fileExists(atPath: switchPath)) {
            throw ActionError("The script returned a file that does not exist")
        }
        let passes = object["passes"]?.boolValue
        if purpose == .condition && passes == nil { throw ActionError("Script condition must return true or false") }
        return Result(stop: stop, switchPath: switchPath, attributes: attributes, orderedAttributes: orderedAttributes, passes: passes)
    }

    /// Bound nesting and token count before handing untrusted script output to
    /// the recursive decoder. JSONDecoder remains responsible for syntax.
    static func resultWithinLimits(_ data: Data) -> Bool {
        var depth = 0, tokens = 0
        var quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                continue
            }
            switch byte {
            case 34: quoted = true; tokens += 1
            case 91, 123: depth += 1; tokens += 1; if depth > 32 { return false }
            case 93, 125: depth -= 1; if depth < 0 { return false }
            case 44, 58: tokens += 1
            default: break
            }
            if tokens > 30_000 { return false }
        }
        return !quoted && depth == 0
    }

    private static let legacyDriver = #"""
    use framework "Foundation"
    use scripting additions
    on run argv
      set scriptObject to load script (POSIX file (item 1 of argv) as alias)
      set matchedFile to POSIX file (item 2 of argv) as alias
      tell scriptObject to set scriptResult to hazelProcessFile(matchedFile)
      set output to current application's NSMutableDictionary's dictionary()
      output's setObject:false forKey:"stop"
      output's setObject:(current application's NSDictionary's dictionary()) forKey:"attributes"
      output's setObject:(current application's NSArray's array()) forKey:"orderedAttributes"
      set hasRecord to false
      try
        set hasRecord to class of scriptResult is record
      on error number -2753
        set hasRecord to false
      end try
      if hasRecord then
        try
          set stopValue to hazelStop of scriptResult
          if class of stopValue is not boolean then error "hazelStop must be a boolean"
          output's setObject:stopValue forKey:"stop"
        on error errorMessage number errorNumber
          if errorNumber is not -1728 then error errorMessage number errorNumber
        end try
        try
          set targetFile to hazelSwitchFile of scriptResult
          set targetPath to POSIX path of (targetFile as alias)
          output's setObject:targetPath forKey:"switchPath"
        on error errorMessage number errorNumber
          if errorNumber is not -1728 then error errorMessage number errorNumber
        end try
        try
          set returnedAttributes to hazelOutputAttributes of scriptResult
          error "Legacy script output attributes are not configured"
        on error errorMessage number errorNumber
          if errorNumber is not -1728 then error errorMessage number errorNumber
        end try
      end if
      set jsonData to current application's NSJSONSerialization's dataWithJSONObject:output options:0 |error|:(missing value)
      if jsonData is missing value then error "Cannot encode script result"
      set success to jsonData's writeToFile:(item 3 of argv) atomically:true
      if success is false then error "Cannot write script result"
    end run
    """#

    private static let driver = #"""
    ObjC.import('Foundation'); ObjC.import('OSAKit');
    function readText(path) {
      const data = $.NSData.dataWithContentsOfFile(path);
      if (!data) throw Error('Cannot read script data');
      return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
    }
    const D = $.NSAppleEventDescriptor;
    function desc(value) {
      if (typeof value === 'string') return D.descriptorWithString(value);
      if (typeof value === 'boolean') return D.descriptorWithBoolean(value);
      if (typeof value === 'number' && Number.isFinite(value)) return D.descriptorWithDouble(value);
      if (value === null) return D.nullDescriptor;
      if (typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 1 && typeof value.__forelDate === 'number' && Number.isFinite(value.__forelDate))
        return D.descriptorWithDate($.NSDate.dateWithTimeIntervalSince1970(value.__forelDate));
      if (Array.isArray(value)) {
        let list = D.listDescriptor;
        value.forEach((v, i) => list.insertDescriptorAtIndex(desc(v), i + 1));
        return list;
      }
      throw Error('Unsupported input attribute type');
    }
    function four(s) { return ((s.charCodeAt(0)<<24)|(s.charCodeAt(1)<<16)|(s.charCodeAt(2)<<8)|s.charCodeAt(3)) >>> 0; }
    function fromDescriptor(d) {
      const t = d.descriptorType >>> 0;
      if (t === four('null')) return null;
      if (t === four('true')) return true;
      if (t === four('fals')) return false;
      if (t === four('bool')) return Boolean(d.booleanValue);
      if ([four('shor'),four('long'),four('comp'),four('doub'),four('sing')].includes(t)) return Number(ObjC.unwrap(d.stringValue));
      if ([four('utxt'),four('TEXT'),four('utf8')].includes(t)) return ObjC.unwrap(d.stringValue);
      if (t === four('ldt ')) {
        const date=d.dateValue; if (!date) throw Error('Invalid script date');
        return {__forelDate: Number(date.timeIntervalSince1970)};
      }
      if (t === four('furl') || t === four('alis') || t === four('obj ')) {
        const u = d.fileURLValue; if (!u) throw Error('Invalid returned file');
        return { __forelFile: ObjC.unwrap(u.path) };
      }
      if (t === four('list')) {
        let a=[]; for(let i=1;i<=d.numberOfItems;i++) a.push(fromDescriptor(d.descriptorAtIndex(i))); return a;
      }
      if (t === four('reco')) {
        const fields=d.descriptorForKeyword(four('usrf')); let o={};
        if (!fields) throw Error('Unsupported script record');
        if (fields.numberOfItems % 2) throw Error('Malformed script record');
        for(let i=1;i<=fields.numberOfItems;i+=2) {
          const key=ObjC.unwrap(fields.descriptorAtIndex(i).stringValue);
          if (typeof key !== 'string') throw Error('Invalid script record key');
          o[key]=fromDescriptor(fields.descriptorAtIndex(i+1));
        }
        return o;
      }
      throw Error('Unsupported script result type: '+t);
    }
    function run(argv) {
      const [language,mode,purpose,sourcePath,filePath,inputPath,resultPath]=argv;
      const handler=purpose === 'condition' ? 'hazelMatchFile' : 'hazelProcessFile';
      const errors=Ref(); let script;
      if (mode === 'embedded' || mode === 'sourceHandler') {
        const code=readText(sourcePath);
        const wrapped=mode === 'sourceHandler' ? code : language === 'AppleScript'
          ? 'on '+handler+'(theFile, inputAttributes)\n'+code+'\nend '+handler
          : 'function '+handler+'(theFile, inputAttributes) {\n'+code+'\n}';
        script=$.OSAScript.alloc.initWithSourceLanguage(wrapped,$.OSALanguage.languageForName(language));
        if (!script.compileAndReturnError(errors)) throw Error('Script compilation failed');
      } else {
        script=$.OSAScript.alloc.initWithContentsOfURLError($.NSURL.fileURLWithPath(sourcePath),errors);
        if (script.isNil()) throw Error('Cannot load compiled script');
      }
      const event=D.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(four('ascr'),four('psbr'),D.nullDescriptor,-1,0);
      event.setParamDescriptorForKeyword(D.descriptorWithString(handler),four('snam'));
      let args=D.listDescriptor;
      const file=D.descriptorWithFileURL($.NSURL.fileURLWithPath(filePath)).coerceToDescriptorType(four('alis'));
      if (!file) throw Error('Cannot create file alias');
      args.insertDescriptorAtIndex(file,1);
      if (mode !== 'legacy') args.insertDescriptorAtIndex(desc(JSON.parse(readText(inputPath))),2);
      event.setParamDescriptorForKeyword(args,four('----'));
      const result=script.executeAppleEventError(event,errors);
      if (result.isNil()) throw Error('Script execution failed');
      let control={stop:false,attributes:{},orderedAttributes:[]};
      if (purpose === 'condition' && [four('true'),four('fals'),four('bool')].includes(result.descriptorType >>> 0)) control.passes=fromDescriptor(result);
      if ((result.descriptorType >>> 0) === four('reco')) {
        const record={}; const fields=result.descriptorForKeyword(four('usrf'));
        if (!fields || fields.numberOfItems % 2) throw Error('Malformed script record');
        for(let i=1;i<=fields.numberOfItems;i+=2) {
          const key=ObjC.unwrap(fields.descriptorAtIndex(i).stringValue);
          if (['hazelStop','hazelSwitchFile','hazelPassesScript','hazelOutputAttributes'].includes(key)) record[key]=fromDescriptor(fields.descriptorAtIndex(i+1));
        }
        if ('hazelStop' in record) {
          if (typeof record.hazelStop !== 'boolean') throw Error('hazelStop must be a boolean');
          control.stop=record.hazelStop;
        }
        if ('hazelPassesScript' in record) {
          if (typeof record.hazelPassesScript !== 'boolean') throw Error('hazelPassesScript must be a boolean');
          control.passes=record.hazelPassesScript;
        }
        if ('hazelSwitchFile' in record) {
          if (!record.hazelSwitchFile || typeof record.hazelSwitchFile.__forelFile !== 'string') throw Error('hazelSwitchFile must be a file');
          control.switchPath=record.hazelSwitchFile.__forelFile;
        }
        if ('hazelOutputAttributes' in record) {
          const a=record.hazelOutputAttributes;
          if (!a || typeof a !== 'object' || Array.isArray(a)) throw Error('hazelOutputAttributes must be a record');
          control.attributes=a;
          control.orderedAttributes=Object.keys(a).map(k => a[k]);
        }
      }
      const writeError=Ref();
      if (!$.NSString.stringWithString(JSON.stringify(control)).writeToFileAtomicallyEncodingError(resultPath,true,$.NSUTF8StringEncoding,writeError)) throw Error('Cannot write script result');
    }
    """#
}
