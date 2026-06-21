import AppKit
import Foundation
import ForelCore

/// Checks GitHub Releases for a newer tagged version and installs it in
/// place: downloads the matching .dmg, then hands off to a detached helper
/// script that waits for this process to quit, mounts the image, swaps the
/// app bundle (with a backup it restores on failure), and relaunches.
/// Forel ships ad-hoc signed (no Apple Developer ID, no notarization, no
/// EdDSA update signature like Sparkle uses), so the only trust boundary
/// here is HTTPS to the hardcoded official repo's GitHub Releases API —
/// there is no cryptographic proof the downloaded binary came from this
/// project's maintainer.
@MainActor
final class UpdaterManager: ObservableObject {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlUrl: URL
        let body: String
        let assets: [Asset]
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
            case assets
            case draft
            case prerelease
        }
    }

    private static let repo = "lab421/forel"
    private static let checkInterval: TimeInterval = 12 * 60 * 60
    private static let settingKey = "auto_update_checks"

    /// Matches the `dmg_suffix` naming in build.sh.
    private static var archSuffix: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x86_64"
        #endif
    }

    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var installError: String?
    @Published var showReleaseNotes = true
    @Published var releaseNotes: (version: String, body: String, url: URL)? = ("1.0.0", "- Correction bug X\n- Nouveau filtre Y", URL(string: "https://github.com/lab421/forel/releases/tag/v1.0.0")!)

    private let db: Database
    private var timer: Timer?
    private var pendingAssetURL: URL?

    init(db: Database) {
        self.db = db
        let stored = try? db.getSetting(Self.settingKey)
        autoCheck = stored.map { $0 != "0" } ?? true
        if autoCheck {
            scheduleAutomaticChecks()
            checkForUpdates()
        }
    }

    private var autoCheck: Bool

    var automaticallyChecksForUpdates: Bool {
        get { autoCheck }
        set {
            guard newValue != autoCheck else { return }
            autoCheck = newValue
            try? db.setSetting(Self.settingKey, newValue ? "1" : "0")
            if newValue {
                scheduleAutomaticChecks()
                checkForUpdates()
            } else {
                timer?.invalidate()
                timer = nil
            }
        }
    }

    /// A dev build (`swift run` / `./build.sh dev`) is a bare executable, not
    /// a packaged `.app` — there's no Info.plist, so `CFBundleShortVersionString`
    /// reads as `nil` and falls back to "0", which makes literally any real
    /// release look newer. Nothing to install anyway outside a packaged app
    /// (see `installUpdate()`'s own check), so just don't check at all.
    private var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func checkForUpdates() {
        guard isPackagedApp else { return }
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            guard let release = await Self.fetchLatestRelease() else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let latest = Self.version(of: release)
            guard Self.isNewer(latest, than: current) else { return }

            // The release notes/publish step (`action-gh-release`) creates the
            // GitHub Release and then uploads its .dmg assets — there's a real
            // window, while a tag's workflow is still running, where the
            // release is already visible via the API but the matching asset
            // isn't attached yet. Don't announce an update the user can't
            // actually download; the next check (or "Check Now") will pick it
            // up once the asset shows up.
            guard let asset = release.assets.first(where: {
                $0.name.hasSuffix(".dmg") && $0.name.contains(Self.archSuffix)
            }) else { return }

            updateAvailable = true
            latestVersion = latest
            releaseURL = release.htmlUrl
            pendingAssetURL = asset.browserDownloadURL
        }
    }

    func openReleasePage() {
        guard let releaseURL else { return }
        NSWorkspace.shared.open(releaseURL)
    }

    /// Downloads the matching .dmg, then hands off to a detached shell
    /// helper that waits for this process to quit before swapping the app
    /// bundle, so the install never touches files this process still has
    /// open. Falls back to opening the release page if anything about the
    /// automatic path isn't available (no matching asset, not running from
    /// a packaged .app, install failure).
    func installUpdate() {
        guard !isInstalling else { return }
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app", let assetURL = pendingAssetURL else {
            openReleasePage()
            return
        }
        isInstalling = true
        installError = nil
        Task {
            do {
                let dmgURL = try await Self.download(assetURL)
                try Self.launchInstallerAndQuit(dmgURL: dmgURL, appURL: appURL)
            } catch {
                isInstalling = false
                installError = "\(error)"
                openReleasePage()
            }
        }
    }

    private func scheduleAutomaticChecks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
    }

    /// Fetches the actual highest-versioned release rather than trusting
    /// GitHub's `/releases/latest`, whose "latest" flag is set at publish
    /// time and can lag behind (e.g. a beta published after an alpha that
    /// never got re-flagged as latest) — comparing every release ourselves
    /// can't go stale that way.
    private static func fetchLatestRelease() async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { return nil }
        return releases
            .filter { !$0.draft && !$0.prerelease }
            .max { lhs, rhs in compareVersions(version(of: lhs), version(of: rhs)) == .orderedAscending }
    }

    private static func version(of release: GitHubRelease) -> String {
        release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
    }

    /// Loads the section of CHANGELOG.md for the currently installed version
    /// and populates `releaseNotes` so the UI can show a sheet.
    func loadReleaseNotesFromChangelog() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        loadReleaseNotesFromChangelog(version: current)
    }

    /// Loads the section of CHANGELOG.md matching `version` (or the first
    /// versioned section if `version` is nil).
    func loadReleaseNotesFromChangelog(version: String?) {
        guard let url = Bundle.module.url(forResource: "CHANGELOG", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: .newlines)
        let header = version.map { "## [\($0)]" }
        var sectionLines: [String] = []
        var inSection = false
        var foundFirst = false

        for line in lines {
            if line.hasPrefix("## [") {
                if inSection { break }
                if let header {
                    if line.hasPrefix(header) {
                        inSection = true
                    }
                } else if !foundFirst {
                    inSection = true
                    foundFirst = true
                }
                continue
            }
            if inSection {
                sectionLines.append(line)
            }
        }

        let body = sectionLines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let v = version ?? Self.findFirstVersion(in: lines)
        if let url = URL(string: "https://github.com/\(Self.repo)/releases/tag/v\(v)") {
            releaseNotes = (v, body, url)
        }
        showReleaseNotes = true
    }

    private static func findFirstVersion(in lines: [String]) -> String {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## [") {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 4)
                if let end = trimmed.firstIndex(of: "]") {
                    return String(trimmed[start..<end])
                }
            }
        }
        return "0.0.0"
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compareVersions(candidate, current) == .orderedDescending
    }

    /// Semver-ish comparison: numeric `major.minor.patch` core, then a
    /// stable release outranks any prerelease, and prereleases compare
    /// their dot-separated identifiers left to right (numeric identifiers
    /// numerically, others lexically — which conveniently also gives the
    /// right "alpha" < "beta" < "rc" ordering). This matters because the
    /// naive "split on every dot and compare as numbers" approach used
    /// before this would parse "alpha.8" and "beta.1" as the *same* leading
    /// components and then compare 8 vs 1, concluding alpha.8 > beta.1.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let (lhsCore, lhsPre) = splitVersion(lhs)
        let (rhsCore, rhsPre) = splitVersion(rhs)
        let coreResult = compareCore(lhsCore, rhsCore)
        guard coreResult == .orderedSame else { return coreResult }
        switch (lhsPre, rhsPre) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (lhsId?, rhsId?): return comparePrerelease(lhsId, rhsId)
        }
    }

    private static func splitVersion(_ version: String) -> (core: [Int], prerelease: String?) {
        let parts = version.split(separator: "-", maxSplits: 1)
        let core = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        let prerelease = parts.count > 1 ? String(parts[1]) : nil
        return (core, prerelease)
    }

    private static func compareCore(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let lhsPart = index < lhs.count ? lhs[index] : 0
            let rhsPart = index < rhs.count ? rhs[index] : 0
            if lhsPart != rhsPart { return lhsPart < rhsPart ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsIds = lhs.split(separator: ".").map(String.init)
        let rhsIds = rhs.split(separator: ".").map(String.init)
        let count = max(lhsIds.count, rhsIds.count)
        for index in 0..<count {
            guard index < lhsIds.count else { return .orderedAscending }
            guard index < rhsIds.count else { return .orderedDescending }
            let lhsId = lhsIds[index]
            let rhsId = rhsIds[index]
            if let lhsNumber = Int(lhsId), let rhsNumber = Int(rhsId) {
                if lhsNumber != rhsNumber { return lhsNumber < rhsNumber ? .orderedAscending : .orderedDescending }
            } else if lhsId != rhsId {
                return lhsId < rhsId ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    private static func download(_ assetURL: URL) async throws -> URL {
        let (tempLocation, _) = try await URLSession.shared.download(from: assetURL)
        let dmgURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
        try? FileManager.default.removeItem(at: dmgURL)
        try FileManager.default.moveItem(at: tempLocation, to: dmgURL)
        return dmgURL
    }

    /// Writes the swap helper to a temp script, spawns it detached from this
    /// process, then quits — the script does the actual mount/swap/relaunch
    /// once it sees this process' PID has exited, so nothing ever touches
    /// the app bundle while it's still running. No codesign/spctl check
    /// here (unlike a Developer-ID-signed app would do): an ad-hoc identity
    /// has no stable team ID to verify against, so that step would be
    /// theater, not a real trust boundary.
    private static func launchInstallerAndQuit(dmgURL: URL, appURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        APP="$1"; DMG="$2"; PID="$3"
        SCRIPT="$0"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
        MNT="$(/usr/bin/mktemp -d)" || { /usr/bin/open "$APP"; /bin/rm -f "$SCRIPT"; exit 1; }
        if ! /usr/bin/hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MNT"; then
            /bin/rmdir "$MNT" 2>/dev/null
            /bin/rm -f "$DMG" "$SCRIPT"
            /usr/bin/open "$APP"
            exit 1
        fi
        SRC="$(/usr/bin/find "$MNT" -maxdepth 1 -name '*.app' -print -quit)"
        LAUNCH="$APP"
        if [ -n "$SRC" ]; then
            DEST="$(/usr/bin/dirname "$APP")/$(/usr/bin/basename "$SRC")"
            STAGE="$DEST.update-new"
            /bin/rm -rf "$STAGE"
            if /usr/bin/ditto "$SRC" "$STAGE"; then
                /usr/bin/xattr -cr "$STAGE" 2>/dev/null
                BACKUP="$DEST.update-old"
                /bin/rm -rf "$BACKUP"
                OK=1
                if [ -d "$DEST" ]; then
                    /bin/mv "$DEST" "$BACKUP" || OK=0
                fi
                if [ "$OK" = "1" ] && /bin/mv "$STAGE" "$DEST"; then
                    LAUNCH="$DEST"
                    /bin/rm -rf "$BACKUP"
                    if [ "$DEST" != "$APP" ]; then /bin/rm -rf "$APP"; fi
                else
                    if [ -d "$BACKUP" ] && [ ! -d "$DEST" ]; then /bin/mv "$BACKUP" "$DEST"; fi
                fi
            fi
            /bin/rm -rf "$STAGE"
        fi
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null || /usr/bin/hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
        /bin/rmdir "$MNT" 2>/dev/null
        /bin/rm -f "$DMG" "$SCRIPT"
        /usr/bin/open "$LAUNCH" --args -forelAfterUpdate
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("forel-update-\(pid)-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, appURL.path, dmgURL.path, "\(pid)"]
        try process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}
