import Foundation

public struct LicenseRecord: Codable, Equatable {
    public var lastObservedAt: Date
    public var trialIsValid: Bool? = nil
    public var trialLastCheckedAt: Date? = nil
    public var trialDaysRemaining: Int? = nil
    public var trialToken: String? = nil
    public var licenseKey: String? = nil
    public var licenseIsValid: Bool? = nil
    public var invalidReason: LicenseInvalidReason? = nil
    public var lastValidatedAt: Date? = nil
    public var licenseToken: String? = nil

    public init(
        lastObservedAt: Date,
        trialIsValid: Bool? = nil,
        trialLastCheckedAt: Date? = nil,
        trialDaysRemaining: Int? = nil,
        trialToken: String? = nil,
        licenseKey: String? = nil,
        licenseIsValid: Bool? = nil,
        invalidReason: LicenseInvalidReason? = nil,
        lastValidatedAt: Date? = nil,
        licenseToken: String? = nil
    ) {
        self.lastObservedAt = lastObservedAt
        self.trialIsValid = trialIsValid
        self.trialLastCheckedAt = trialLastCheckedAt
        self.trialDaysRemaining = trialDaysRemaining
        self.trialToken = trialToken
        self.licenseKey = licenseKey
        self.licenseIsValid = licenseIsValid
        self.invalidReason = invalidReason
        self.lastValidatedAt = lastValidatedAt
        self.licenseToken = licenseToken
    }
}

public enum LicenseAccessState: Equatable, Sendable {
    case bypassed
    case trial
    case trialUnverified
    case trialExpired
    case licensed
    case invalid(LicenseInvalidReason)

    public var grantsAccess: Bool {
        switch self {
        case .bypassed, .trial, .licensed: true
        case .trialUnverified, .trialExpired, .invalid: false
        }
    }

    public var isDefinitivelyDenied: Bool {
        switch self {
        case .trialExpired, .invalid: true
        case .bypassed, .trial, .trialUnverified, .licensed: false
        }
    }
}

public enum LicenseInvalidReason: String, Codable, Equatable, Error, Sendable {
    case licenseNotFound = "license_not_found"
    case licenseDisabled = "license_disabled"
    case licenseExpired = "license_expired"
    case deviceNotActivated = "device_not_activated"
    case deviceDeactivated = "device_deactivated"
    case unknown

    public init(serverValue: String?) {
        self = serverValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

public enum TrialInvalidReason: String, Codable, Equatable, Error, Sendable {
    case trialNotStarted = "trial_not_started"
    case trialExpired = "trial_expired"
    case unknown

    public init(serverValue: String?) {
        self = serverValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

public struct TrialStatus: Equatable, Sendable {
    public let daysRemaining: Int
    public let expiresAt: Date
    public let trialToken: String?

    public init(daysRemaining: Int, expiresAt: Date, trialToken: String?) {
        self.daysRemaining = daysRemaining
        self.expiresAt = expiresAt
        self.trialToken = trialToken
    }
}

public struct LicenseAPIError: Error, Equatable {
    public let code: String
    public let message: String
    public let field: String?
}

public struct OfflineLicensePayload: Equatable {
    public var licenseKey: String?
    public var deviceID: String
    public var productID: String
    public var validUntil: Date?
}

public enum OfflineLicenseTokenError: Error, Equatable {
    case malformed
    case invalidSignature
    case deviceMismatch
    case expired
}

@MainActor
public protocol LicenseSecureStoring {
    func load() throws -> LicenseRecord?
    func save(_ record: LicenseRecord) throws
}

public protocol DeviceIdentifierProviding: Sendable {
    var deviceID: String { get }
}

public protocol LicenseAPIClientProtocol: Sendable {
    func startTrial(deviceID: String, product: String, deviceName: String?, deviceProfile: DeviceProfile?) async throws
    func trialStatus(deviceID: String, product: String) async throws -> Result<TrialStatus, TrialInvalidReason>
    func activate(
        licenseKey: String,
        deviceID: String,
        deviceName: String?,
        deviceProfile: DeviceProfile?
    ) async throws -> String?
    func validate(licenseKey: String, deviceID: String) async throws -> Result<String?, LicenseInvalidReason>
    func deactivate(licenseKey: String, deviceID: String) async throws
}
