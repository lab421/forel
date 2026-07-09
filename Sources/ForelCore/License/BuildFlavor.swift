#if FOREL_BUILD_DEVELOPMENT && FOREL_BUILD_AD_HOC
#error("Only one Forel build flavor can be enabled")
#endif
#if FOREL_BUILD_DEVELOPMENT && FOREL_BUILD_APP_STORE
#error("Only one Forel build flavor can be enabled")
#endif
#if FOREL_BUILD_AD_HOC && FOREL_BUILD_APP_STORE
#error("Only one Forel build flavor can be enabled")
#endif

public enum BuildFlavor: String, CaseIterable, Sendable {
    case development
    case adHoc = "ad-hoc"
    case appStore = "app-store"

    public static var current: BuildFlavor {
        #if FOREL_BUILD_APP_STORE
        return .appStore
        #elseif FOREL_BUILD_AD_HOC
        return .adHoc
        #else
        return .development
        #endif
    }

    public var capabilities: BuildCapabilities {
        switch self {
        case .development:
            BuildCapabilities(
                usesDirectLicensing: false,
                directLicenseTrialDays: nil,
                supportsSelfUpdates: true
            )
        case .adHoc:
            BuildCapabilities(
                usesDirectLicensing: true,
                directLicenseTrialDays: 7,
                supportsSelfUpdates: true
            )
        case .appStore:
            BuildCapabilities(
                usesDirectLicensing: false,
                directLicenseTrialDays: nil,
                supportsSelfUpdates: false
            )
        }
    }
}

public struct BuildCapabilities: Equatable, Sendable {
    public let usesDirectLicensing: Bool
    public let directLicenseTrialDays: Int?
    public let supportsSelfUpdates: Bool

    public static var current: BuildCapabilities {
        BuildFlavor.current.capabilities
    }
}
