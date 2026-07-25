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

import Foundation
import Darwin
import ImageIO
import PDFKit

public enum ConditionEvaluator {
    /// Returns true if the file at `path` satisfies the condition.
    public static func evaluate(_ condition: Condition, path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)

        switch condition.kind {
        case .name:
            return matchName(condition.operator, url: url, condition.value)

        case .extension_:
            let ext = url.pathExtension.lowercased()
            let value = condition.value.trimmingPrefix(while: { $0 == "." }).lowercased()
            return matchString(condition.operator, ext, value)

        case .kind:
            guard let attrs else { return false }
            let detected = detectKind(path: path, attrs: attrs)
            switch condition.operator {
            case .is: return detected == condition.value
            case .isNot: return detected != condition.value
            default: return false
            }

        case .sizeBytes:
            guard let attrs else { return false }
            let size = (attrs[.size] as? UInt64) ?? 0
            let threshold = parseSize(condition.value)
            switch condition.operator {
            case .is: return size == threshold
            case .isNot: return size != threshold
            case .greaterThan: return size > threshold
            case .lessThan: return size < threshold
            default: return false
            }

        case .tags:
            let target = condition.value.trimmingCharacters(in: .whitespaces).lowercased()
            let names = FinderTags.read(path).map { tagName($0).lowercased() }
            switch condition.operator {
            case .is: return names.contains(target)
            case .isNot: return !names.contains(target)
            case .contains: return names.contains { $0.contains(target) }
            case .doesNotContain: return !names.contains { $0.contains(target) }
            case .startsWith: return names.contains { $0.hasPrefix(target) }
            case .endsWith: return names.contains { $0.hasSuffix(target) }
            case .matchesRegex:
                guard let re = try? NSRegularExpression(pattern: condition.value) else { return false }
                return names.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            default: return false
            }

        case .colorLabel:
            let target = condition.value.lowercased()
            let has = FinderTags.read(path).contains { tagName($0).lowercased() == target }
            switch condition.operator {
            case .is: return has
            case .isNot: return !has
            default: return false
            }

        case .contents:
            return evaluateContents(condition, path: path).matched

        case .createdAt:
            guard let attrs else { return false }
            guard let created = attrs[.creationDate] as? Date else { return false }
            return matchDate(condition.operator, created, condition.value)

        case .dateModified:
            guard let attrs else { return false }
            guard let modified = attrs[.modificationDate] as? Date else { return false }
            return matchDate(condition.operator, modified, condition.value)

        case .dateAdded:
            guard let added = dateAdded(path: path) else { return false }
            return matchDate(condition.operator, added, condition.value)

        case .finderComment:
            guard let comment = FinderTags.readComment(path) else { return false }
            return matchString(condition.operator, comment, condition.value)

        case .filePath:
            return matchString(condition.operator, path, condition.value)

        case .itemCount:
            guard let count = itemCount(path: path) else { return false }
            return matchNumber(condition.operator, count, condition.value)

        case .lastOpened:
            guard let accessed = try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate else { return false }
            return matchDate(condition.operator, accessed, condition.value)

        case .imageWidth:
            guard let dimensions = imageDimensions(path: path) else { return false }
            return matchNumber(condition.operator, dimensions.width, condition.value)

        case .imageHeight:
            guard let dimensions = imageDimensions(path: path) else { return false }
            return matchNumber(condition.operator, dimensions.height, condition.value)

        case .photoDateTaken:
            guard let taken = photoDateTaken(path: path) else { return false }
            return matchDate(condition.operator, taken, condition.value)

        case .pdfPageCount:
            guard let pageCount = PDFDocument(url: url)?.pageCount else { return false }
            return matchNumber(condition.operator, Double(pageCount), condition.value)

        case .spotlightMetadata:
            guard let (key, value) = SpotlightMetadataCondition.parse(condition.value),
                  let metadata = spotlightMetadata(path: path, key: key) else { return false }
            return matchString(condition.operator, metadata, value)

        case .downloadedFromWebsite:
            return matchAnyOf(condition.operator, DownloadMetadata.websiteURLs(path), condition.value)

        case .downloadedWithApp:
            guard let app = DownloadMetadata.downloadedWithApp(path) else {
                return matchAnyOf(condition.operator, [], condition.value)
            }
            return matchDownloadedApp(condition.operator, app, condition.value)

        case .rawWhereFromMetadata:
            return matchAnyOf(condition.operator, DownloadMetadata.whereFroms(path), condition.value)
        }
    }

    /// Evaluates a `contents` condition, returning the match result together
    /// with which extraction strategy was used and any short reason. The Dry Run
    /// uses the extra detail to explain what was read; `evaluate` discards it.
    /// When no text can be extracted every operator is `false`, so a rule never
    /// matches on content it could not read (including the negative operators).
    static func evaluateContents(_ condition: Condition, path: String) -> (matched: Bool, strategy: ContentStrategy, message: String?) {
        let result = ContentExtractor.extract(path: path)
        if let text = result.text {
            return (matchString(condition.operator, text, condition.value), result.strategy, result.message)
        }
        // Nothing readable in-process. For formats macOS indexes but we can't
        // read directly (e.g. legacy .xls), fall back to Spotlight — which can
        // only confirm a `contains` match, never a negative operator.
        if condition.operator == .contains,
           !condition.value.isEmpty,
           ContentExtractor.supportsSpotlightFallback(path: path),
           ContentExtractor.spotlightContains(path: path, term: condition.value) {
            return (true, .spotlight, nil)
        }
        return (false, result.strategy, result.message)
    }

    /// True if any value in `haystacks` satisfies the operator against
    /// `needle`. `is not`/`does not contain` are defined as the exact
    /// negation of `is`/`contains` across the whole list (same pattern as the
    /// `tags` condition above), which gives the right behavior when the list
    /// is empty — e.g. a file with no download metadata at all: every
    /// positive operator is `false`, every negative operator is `true`.
    private static func matchAnyOf(_ operator_: Operator, _ haystacks: [String], _ needle: String) -> Bool {
        switch operator_ {
        case .is: return haystacks.contains { $0 == needle }
        case .isNot: return !haystacks.contains { $0 == needle }
        case .contains: return haystacks.contains { $0.contains(needle) }
        case .doesNotContain: return !haystacks.contains { $0.contains(needle) }
        case .startsWith: return haystacks.contains { $0.hasPrefix(needle) }
        case .endsWith: return haystacks.contains { $0.hasSuffix(needle) }
        case .matchesRegex:
            guard let re = try? NSRegularExpression(pattern: needle) else { return false }
            return haystacks.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        default:
            return false
        }
    }

    private static func matchDownloadedApp(_ operator_: Operator, _ actual: String, _ expected: String) -> Bool {
        switch operator_ {
        case .is:
            return appNamesMatch(actual: actual, expected: expected)
        case .isNot:
            return !appNamesMatch(actual: actual, expected: expected)
        default:
            return matchAnyOf(operator_, [actual], expected)
        }
    }

    private static func matchNumber(_ operator_: Operator, _ actual: Double, _ expected: String) -> Bool {
        guard let target = Double(expected.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        switch operator_ {
        case .is: return actual == target
        case .isNot: return actual != target
        case .greaterThan: return actual > target
        case .lessThan: return actual < target
        default: return false
        }
    }

    private static func itemCount(path: String) -> Double? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return Double(children.filter { !SystemFileFilter.isExcluded($0) }.count)
    }

    private static func imageDimensions(path: String) -> (width: Double, height: Double)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return (width.doubleValue, height.doubleValue)
    }

    private static func photoDateTaken(path: String) -> Date? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    private static func spotlightMetadata(path: String, key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-name", key, "-raw", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let result = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result, result != "(null)" else { return nil }
        return result
    }

    private static func appNamesMatch(actual: String, expected: String) -> Bool {
        actual == expected || actual == quarantineAgentAlias(forAppName: expected)
    }

    private static func quarantineAgentAlias(forAppName name: String) -> String {
        if name.hasPrefix("Google ") {
            return String(name.dropFirst("Google ".count))
        }
        return name
    }

    /// macOS "Date Added" (when the file was added to its current folder). Not
    /// exposed by `stat`/`FileManager`, so it is read via `getattrlist` with
    /// `ATTR_CMN_ADDEDTIME`. Returns `nil` if the volume does not track it.
    private static func dateAdded(path: String) -> Date? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)

        var buf = [UInt8](repeating: 0, count: 4 + 16)
        let rc = buf.withUnsafeMutableBytes { rawBuf in
            getattrlist(path, &attrList, rawBuf.baseAddress, rawBuf.count, 0)
        }
        guard rc == 0 else { return nil }

        let secs = buf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int64.self) }
        if secs == 0 { return nil }
        let nsecs = buf.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int64.self) }
        return Date(timeIntervalSince1970: Double(secs) + Double(nsecs) / 1_000_000_000)
    }

    /// Matches a file timestamp against a date operator, keyed on the operator
    /// (not the condition kind) so it is reusable by any date condition.
    /// `before`/`after` take a calendar date ("YYYY-MM-DD"); `older_than`/
    /// `within_last` take a relative duration ("30 days"). Invalid values never match.
    private static func matchDate(_ operator_: Operator, _ fileDate: Date, _ value: String) -> Bool {
        switch operator_ {
        case .before:
            guard let day = parseDate(value) else { return false }
            return fileDate < day
        case .after:
            guard let day = parseDate(value), let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) else { return false }
            return fileDate >= nextDay
        case .olderThan:
            guard let cutoff = cutoffDate(value) else { return false }
            return fileDate < cutoff
        case .withinLast:
            guard let cutoff = cutoffDate(value) else { return false }
            return fileDate >= cutoff
        default:
            return false
        }
    }

    /// Parses "YYYY-MM-DD" into midnight local time on that day.
    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    /// Parses a relative duration ("30 days", "2 weeks", "6 months", "1 years")
    /// into the cutoff instant `now - duration`. Months/years use calendar arithmetic.
    private static func cutoffDate(_ value: String) -> Date? {
        let s = value.trimmingCharacters(in: .whitespaces)
        guard let splitIndex = s.firstIndex(where: { !$0.isNumber }) else { return nil }
        let numPart = String(s[s.startIndex..<splitIndex]).trimmingCharacters(in: .whitespaces)
        let unitPart = String(s[splitIndex...]).trimmingCharacters(in: .whitespaces).lowercased()
        guard let n = Int(numPart) else { return nil }

        let now = Date()
        var component: Calendar.Component
        switch unitPart {
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        case "month", "months": component = .month
        case "year", "years": component = .year
        default: return nil
        }
        return Calendar.current.date(byAdding: component, value: -n, to: now)
    }

    /// Classifies a file into a Hazel-style kind string based on its extension.
    private static func detectKind(path: String, attrs: [FileAttributeKey: Any]) -> String {
        let url = URL(fileURLWithPath: path)
        let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        if isDir {
            return url.pathExtension.lowercased() == "app" ? "application" : "folder"
        }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg", "heic", "heif", "raw", "cr2", "cr3", "nef", "arw", "dng":
            return "image"
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm", "mpg", "mpeg":
            return "movie"
        case "mp3", "aac", "flac", "wav", "aiff", "aif", "m4a", "ogg", "wma", "opus":
            return "music"
        case "pdf":
            return "pdf"
        case "txt", "md", "markdown", "rtf", "rst", "log":
            return "text"
        case "ppt", "pptx", "key", "odp":
            return "presentation"
        case "zip", "tar", "gz", "bz2", "7z", "rar", "xz", "zst", "tgz", "tbz", "cab":
            return "archive"
        case "dmg", "iso", "img", "sparseimage", "sparsebundle":
            return "disk_image"
        default:
            return "document"
        }
    }

    private static func matchString(_ operator_: Operator, _ haystack: String, _ needle: String) -> Bool {
        switch operator_ {
        case .is: return haystack == needle
        case .isNot: return haystack != needle
        case .contains: return haystack.contains(needle)
        case .doesNotContain: return !haystack.contains(needle)
        case .startsWith: return haystack.hasPrefix(needle)
        case .endsWith: return haystack.hasSuffix(needle)
        case .matchesRegex:
            guard let re = try? NSRegularExpression(pattern: needle) else { return false }
            return re.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        default:
            return false
        }
    }

    /// Name conditions traditionally operate on the extensionless stem, but
    /// exact comparisons also accept the complete filename. This keeps rules
    /// such as `Name is invoice` working while allowing exclusions copied from
    /// Finder, such as `Name is not Desktop.ini`, to compare the intended name.
    private static func matchName(_ operator_: Operator, url: URL, _ needle: String) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        let fullName = url.lastPathComponent
        switch operator_ {
        case .is:
            return stem == needle || fullName == needle
        case .isNot:
            return stem != needle && fullName != needle
        default:
            return matchString(operator_, stem, needle)
        }
    }

    /// Parses a size threshold into bytes. Accepts a plain number ("5242880")
    /// or a number with a unit suffix ("5 MB", "100kb"). Unitless values are bytes.
    private static func parseSize(_ value: String) -> UInt64 {
        let s = value.trimmingCharacters(in: .whitespaces)
        guard let splitIndex = s.firstIndex(where: { !$0.isNumber && $0 != "." }) else {
            return UInt64(Double(s) ?? 0)
        }
        let numPart = String(s[s.startIndex..<splitIndex]).trimmingCharacters(in: .whitespaces)
        let unitPart = String(s[splitIndex...]).trimmingCharacters(in: .whitespaces).lowercased()
        let n = Double(numPart) ?? 0
        let multiplier: Double
        switch unitPart {
        case "kb": multiplier = 1024
        case "mb": multiplier = 1024 * 1024
        case "gb": multiplier = 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return UInt64(n * multiplier)
    }

    private static func tagName(_ tag: String) -> String {
        let name = tag.split(separator: "\n").first.map(String.init) ?? tag
        return name.trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    func trimmingPrefix(while predicate: (Character) -> Bool) -> String {
        var s = Substring(self)
        while let first = s.first, predicate(first) { s = s.dropFirst() }
        return String(s)
    }
}
