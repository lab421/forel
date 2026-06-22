import Foundation
#if canImport(Photos)
import Photos
#endif

/// Read-only status of a system permission Forel depends on. Surfaced in
/// Settings so the user can see at a glance what's granted and what still
/// needs attention, instead of discovering a missing permission only when a
/// rule silently fails.
public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case restricted
    /// The user hasn't been asked yet (Photos), or the status simply hasn't
    /// been probed this session (Music/TV automation — see
    /// `PermissionsChecker.checkAutomationAccessNow`, the only way to learn it
    /// without guessing, and it requires an explicit user action).
    case unknown
}

/// Centralizes the permission checks `ActionExecutor` already performs as a
/// side effect of running rules, so Settings can show them proactively
/// instead of the user only finding out when an action fails.
public enum PermissionsChecker {
    // MARK: - Photos

    /// Current Photos authorization, queried without prompting.
    public static func photosAccessStatus() -> PermissionStatus {
        #if canImport(Photos)
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
        #else
        return .denied
        #endif
    }

    /// Triggers the system Photos permission prompt if the user hasn't been
    /// asked yet. Only call this from an explicit user action (a "Request
    /// Access" button) — it does nothing but report status if access has
    /// already been decided.
    @discardableResult
    public static func requestPhotosAccess() -> PermissionStatus {
        #if canImport(Photos)
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else {
            return photosAccessStatus()
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = PhotosAuthStatusBox()
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            box.status = status
            semaphore.signal()
        }
        semaphore.wait()
        switch box.status {
        case .authorized, .limited: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .unknown
        }
        #else
        return .denied
        #endif
    }

    // MARK: - Automation (Music / TV)

    /// Whether `app` ("Music" or "TV") already has a running process —
    /// checked via System Events so merely asking doesn't launch it.
    public static func isAppRunning(_ app: String) -> Bool {
        ActionExecutor.isAppRunning(app)
    }

    /// Live automation-permission probe for `app`. This talks to the app over
    /// AppleScript, which **launches it** if it isn't already running —
    /// there's no API to learn Apple Events automation status without
    /// actually attempting one. Only call this from an explicit "Check
    /// Access" button, never from a passive status read (e.g. on a view
    /// simply appearing), so Forel never launches Music or TV as a surprise
    /// side effect of opening Settings.
    public static func checkAutomationAccessNow(app: String) -> PermissionStatus {
        do {
            // Must use the same probe as the real import path's gate — see
            // `ActionExecutor.automationProbeScript`'s doc comment for why a
            // trivial command like `get name` would always report granted.
            _ = try ActionExecutor.runAppleScript(ActionExecutor.automationProbeScript(app: app))
            return .granted
        } catch {
            return .denied
        }
    }
}

#if canImport(Photos)
/// Thread-safe holder for the authorization result delivered on an arbitrary
/// queue; the surrounding semaphore establishes the happens-before ordering.
private final class PhotosAuthStatusBox: @unchecked Sendable {
    var status: PHAuthorizationStatus = .denied
}
#endif
