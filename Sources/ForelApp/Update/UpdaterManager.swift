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
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
        }
    }

    private static let repo = "forel-app/forel"
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

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            guard let release = await Self.fetchLatestRelease() else { return }
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            if Self.isNewer(latest, than: current) {
                updateAvailable = true
                latestVersion = latest
                releaseURL = release.htmlUrl
                pendingAssetURL = release.assets.first {
                    $0.name.hasSuffix(".dmg") && $0.name.contains(Self.archSuffix)
                }?.browserDownloadURL
            }
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

    private static func fetchLatestRelease() async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Compares dot-separated numeric version strings (e.g. "1.2.10" vs "1.2.3").
    /// Missing components are treated as 0, non-numeric components as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
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
        /usr/bin/open "$LAUNCH"
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
