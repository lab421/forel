import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for the "Start at login" preference.
///
/// In an unsigned dev build (a bare executable rather than a packaged `.app`),
/// `SMAppService` registration throws. Callers persist the user's intent
/// regardless, so the preference applies once the app runs from a signed
/// bundle.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let status) where status != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
