import Foundation

/// Looks up this package's own bundled strings (`Resources/*.lproj`).
///
/// Goes through a specific `.lproj` sub-bundle rather than calling
/// `Bundle.module.localizedString` directly: `Bundle.module` doesn't reliably
/// pick the right language for a bare SPM resource bundle (e.g. under
/// `swift run`), so the preferred language is resolved by hand.
enum PackageLocalization {
    /// Test-only override of the resolved language, bypassing the system's
    /// preferred-language resolution below. Not part of the public API —
    /// production code always follows system locale; only visible to tests
    /// via `@testable import`, so they can pin a language and stop depending
    /// on the machine's own locale to know what "the English string"
    /// resolves to. A task-local rather than a plain global: scoped to
    /// whichever task binds it via `withValue`, so parallel tests can't leak
    /// their override into one another.
    @TaskLocal
    static var languageOverrideForTesting: String?

    private static var bundle: Bundle {
        let languageCode: String
        if let languageOverrideForTesting {
            languageCode = languageOverrideForTesting
        } else {
            let preferred = Bundle.preferredLocalizations(
                from: Bundle.module.localizations,
                forPreferences: Locale.preferredLanguages
            )
            languageCode = preferred.first ?? "en"
        }
        let lprojURL = Bundle.module.bundleURL.appendingPathComponent("\(languageCode).lproj")
        if FileManager.default.fileExists(atPath: lprojURL.path),
           let localized = Bundle(url: lprojURL) {
            return localized
        }
        return Bundle.module
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: bundle.localizedString(forKey: key, value: key, table: nil), arguments: arguments)
    }

    static func trialRemainingText(days: Int) -> String {
        days == 1 ? format("trial_day_remaining", days) : format("trial_days_remaining", days)
    }
}

extension LicenseManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .licenseKeyRequired:
            PackageLocalization.string("license_key_required")
        case .storage(let statusCode, let appName):
            PackageLocalization.format("license_storage_error", appName, statusCode)
        case .server(let apiError):
            apiError.message
        case .serverUnavailable:
            PackageLocalization.string("license_server_unavailable")
        case .validationUnavailable:
            PackageLocalization.string("license_validation_unavailable")
        case .importDeviceMismatch:
            PackageLocalization.string("license_import_device_mismatch")
        case .importExpired:
            PackageLocalization.string("license_import_expired")
        case .importInvalid:
            PackageLocalization.string("license_import_invalid")
        }
    }
}

extension LicenseInvalidReason: LocalizedError {
    public var errorDescription: String? {
        PackageLocalization.string("license_reason_\(rawValue)")
    }
}

public extension LicenseAccessState {
    /// Localized status headline for this access state. Carries no icon or
    /// color choice — that's a presentation decision the host app makes.
    var localizedTitle: String {
        switch self {
        case .licensed:
            PackageLocalization.string("license_active")
        case .trial, .trialGracePeriod:
            PackageLocalization.string("trial_mode")
        case .trialUnverified, .trialGracePeriodExpired:
            PackageLocalization.string("trial_unverified")
        case .trialExpired:
            PackageLocalization.string("trial_expired")
        case .invalid:
            PackageLocalization.string("license_invalid")
        case .bypassed:
            PackageLocalization.string("license_not_required")
        }
    }

    /// Localized status detail text.
    /// - Parameters:
    ///   - appName: Interpolated into subtitles that name the app.
    ///   - trialDaysRemaining: Used only for `.trial`, to show a countdown
    ///     once known (`LicenseManager.trialDaysRemaining` is `nil` until the
    ///     first successful server check); falls back to a generic message
    ///     until then.
    func localizedSubtitle(appName: String, trialDaysRemaining: Int?) -> String {
        switch self {
        case .licensed:
            PackageLocalization.format("license_active_subtitle", appName)
        case .trial:
            trialDaysRemaining.map(PackageLocalization.trialRemainingText)
                ?? PackageLocalization.string("trial_active_subtitle")
        case .trialGracePeriod(let deadline):
            PackageLocalization.format("trial_grace_period_subtitle", appName, Self.hoursRemaining(until: deadline))
        case .trialUnverified, .trialGracePeriodExpired:
            PackageLocalization.format("trial_unverified_subtitle", appName)
        case .trialExpired:
            PackageLocalization.string("trial_expired_subtitle")
        case .invalid(let reason):
            reason.localizedDescription
        case .bypassed:
            PackageLocalization.string("license_not_required")
        }
    }

    private static func hoursRemaining(until deadline: Date) -> Int {
        max(1, Int(deadline.timeIntervalSinceNow / 3600))
    }
}
