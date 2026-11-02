import Foundation

/// Moves licensing hints to a dedicated suite without changing the saved license
/// or a fallback device identifier used for activation.
public enum ForelLicensePreferences {
    public static func migrate(to suiteName: String, from legacyDomainName: String, service: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let legacyValues = UserDefaults.standard.persistentDomain(forName: legacyDomainName) ?? [:]
        for key in ["\(service).direct-license.hasPaidLicense", "device.fallbackIdentifier"] {
            if defaults.object(forKey: key) == nil, let value = legacyValues[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}
