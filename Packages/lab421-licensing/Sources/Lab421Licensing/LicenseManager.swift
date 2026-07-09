import AppKit
import Foundation
import IOKit
import Security

public struct LicenseRecord: Codable, Equatable, Sendable {
    public var lastObservedAt: Date
    public var trialIsValid: Bool? = nil
    public var trialLastCheckedAt: Date? = nil
    /// Cached purely for display in the host app's UI (e.g. a trial
    /// countdown) — not consulted anywhere access is decided.
    public var trialDaysRemaining: Int? = nil
    /// Signed offline token cached from the last successful `/trial/status`
    /// response. Like `licenseToken` for a paid license, this is the sole
    /// proof consulted to grant trial access — `trialIsValid` above is
    /// display-only.
    public var trialToken: String? = nil
    public var licenseKey: String? = nil
    public var licenseIsValid: Bool? = nil
    public var invalidReason: LicenseInvalidReason? = nil
    public var lastValidatedAt: Date? = nil
    /// Signed offline token cached from the last `/activate` or `/validate`
    /// success, or from a manually imported license file. Lets the license
    /// keep working forever without the server, per the license server's
    /// offline license verification design.
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

@MainActor
public protocol LicenseSecureStoring {
    func load() throws -> LicenseRecord?
    func save(_ record: LicenseRecord) throws
}

public protocol DeviceIdentifierProviding {
    var deviceID: String { get }
}

public struct HardwareDeviceIdentifierProvider: DeviceIdentifierProviding {
    private static let fallbackIdentifierKey = "device.fallbackIdentifier"

    private let defaults: UserDefaults

    /// - Parameter userDefaultsSuiteName: A suite unique to the consuming
    ///   app (e.g. its bundle identifier), so the random fallback identifier
    ///   used when IOKit's hardware UUID is unavailable doesn't collide with
    ///   another app on the same Mac.
    public init(userDefaultsSuiteName: String) {
        self.defaults = UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard
    }

    public var deviceID: String {
        if let uuid = ioRegistryStringProperty(key: "IOPlatformUUID") {
            return uuid
        }
        if let serialNumber = ioRegistryStringProperty(key: "IOPlatformSerialNumber") {
            return serialNumber
        }
        // IOPlatformUUID/serial are unavailable in some unusual environment.
        // Generate a random identifier once and persist it, so this machine
        // keeps presenting the same device_id to the server on every launch
        // instead of looking like a brand-new device every time.
        if let persisted = defaults.string(forKey: Self.fallbackIdentifierKey) {
            return persisted
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Self.fallbackIdentifierKey)
        return generated
    }

    private func ioRegistryStringProperty(key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

@MainActor
public final class KeychainLicenseStore: LicenseSecureStoring {
    private let service: String
    private let account: String

    /// - Parameters:
    ///   - service: A Keychain service string unique to the consuming app
    ///     (e.g. `"com.example.myapp.license"`), so multiple apps using this
    ///     package don't share a Keychain item.
    ///   - account: Defaults to `"direct-license"`; override only if an app
    ///     needs multiple independent license records.
    public init(service: String, account: String = "direct-license") {
        self.service = service
        self.account = account
    }

    public func load() throws -> LicenseRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LicenseRecord.self, from: data)
    }

    public func save(_ record: LicenseRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public struct KeychainError: Error {
        public let status: OSStatus
    }
}

public enum LicenseAccessState: Equatable, Sendable {
    case bypassed
    case trial
    /// Not yet confirmed — either never checked (e.g. first launch with no
    /// cached trial token) or the last check yielded no verifiable proof.
    /// Like an unconfirmed license without a signed offline token, this is
    /// denied until a fresh, verifiable proof (server round-trip or cached
    /// signed trial token) resolves it.
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

    /// Denied for a confirmed reason, as opposed to merely not yet checked.
    /// `.trialUnverified` is the synchronous state at the very start of every
    /// launch until the first server round-trip resolves it (typically to
    /// `.trial` within moments) — interrupting the user with the license
    /// window for that transient state would fire on every single launch.
    public var isDefinitivelyDenied: Bool {
        switch self {
        case .trialExpired, .invalid: true
        case .bypassed, .trial, .trialUnverified, .licensed: false
        }
    }
}

/// Everything a host app can display about a licensing failure. Carries no
/// localized text — the host owns its own strings and localization, and maps
/// each case (plus, for `.server`, the server-supplied message) to whatever
/// it wants to show the user.
public enum LicenseManagerError: Error, Equatable, Sendable {
    case licenseKeyRequired
    /// `appName` is carried on the case (rather than looked up separately at
    /// display time) so `errorDescription` can mention the host app by name
    /// without needing any extra context from the caller.
    case storage(statusCode: Int, appName: String)
    case server(LicenseAPIError)
    case serverUnavailable
    case validationUnavailable
    case importDeviceMismatch
    case importExpired
    case importInvalid
}

@MainActor
public final class LicenseManager: ObservableObject {
    public static let validationInterval: TimeInterval = 24 * 60 * 60
    public static let trialSyncInterval = validationInterval

    @Published public private(set) var state: LicenseAccessState
    @Published public private(set) var isWorking = false
    @Published public private(set) var lastError: LicenseManagerError?

    private let isEnabled: Bool
    private let productID: String
    private let secureStore: any LicenseSecureStoring
    private let client: any LicenseAPIClientProtocol
    private let now: () -> Date
    private let offlineTokenPublicKeyRaw: Data
    /// This device's hardware identifier, resolved once at launch. Never
    /// persisted: it's cheap and deterministic to recompute, and not trusting
    /// a stored copy is what makes it impossible for a `LicenseRecord` copied
    /// from another Mac's Keychain to pass as licensed here (see
    /// `state(for:)`).
    private let deviceID: String
    public let deviceName: String
    /// Shown in error messages that need to name the app (e.g. a Keychain
    /// storage failure telling the user to quit and reopen it).
    private let appName: String
    private var record: LicenseRecord?
    private var trialSyncTimer: Timer?

    /// - Parameters:
    ///   - isEnabled: Whether this build/distribution channel uses direct
    ///     licensing at all (e.g. `false` for a Mac App Store build, which is
    ///     gated by StoreKit instead). When `false`, the manager always
    ///     reports `.bypassed` / `hasAccess == true` and never talks to the
    ///     network or Keychain.
    ///   - productID: The `product_id` this app registers trials under on
    ///     the shared license server.
    ///   - appName: This app's display name, e.g. `"Ombrelle"`. Interpolated
    ///     into user-facing error text such as the Keychain storage failure.
    ///   - deviceNameFallback: Shown/sent when `Host.current().localizedName`
    ///     is unavailable. Pass an already-localized string.
    ///   - secureStore: Typically a `KeychainLicenseStore` configured with
    ///     this app's own Keychain service string.
    ///   - deviceIdentifierProvider: Typically a
    ///     `HardwareDeviceIdentifierProvider` configured with this app's own
    ///     `UserDefaults` suite.
    ///   - offlineTokenPublicKeyRaw: The raw Ed25519 public key matching the
    ///     signing key used by this app's license server.
    ///   - baseURL: The license server's base URL. Defaults to the shared
    ///     `api.ombrelle.app` server; override for a different backend.
    ///     Ignored if `client` is provided.
    ///   - client: Full override of the networking layer, e.g. a mock in
    ///     tests. Defaults to a `LicenseAPIClient` built from `baseURL`.
    public init(
        isEnabled: Bool,
        productID: String,
        appName: String,
        deviceNameFallback: String,
        secureStore: any LicenseSecureStoring,
        deviceIdentifierProvider: any DeviceIdentifierProviding,
        offlineTokenPublicKeyRaw: Data,
        baseURL: URL = LicenseAPIClient.defaultBaseURL,
        client: (any LicenseAPIClientProtocol)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.isEnabled = isEnabled
        self.productID = productID
        self.appName = appName
        self.secureStore = secureStore
        self.client = client ?? LicenseAPIClient(baseURL: baseURL)
        self.now = now
        self.offlineTokenPublicKeyRaw = offlineTokenPublicKeyRaw
        self.deviceID = deviceIdentifierProvider.deviceID
        self.deviceName = Host.current().localizedName ?? deviceNameFallback

        guard isEnabled else {
            state = .bypassed
            return
        }

        let currentDate = now()
        do {
            record = try secureStore.load() ?? LicenseRecord(lastObservedAt: currentDate)
        } catch {
            record = LicenseRecord(lastObservedAt: currentDate)
            lastError = Self.storageError(for: error, appName: appName)
        }

        state = Self.state(
            for: record!,
            deviceID: deviceID,
            now: currentDate,
            offlineTokenPublicKeyRaw: offlineTokenPublicKeyRaw
        )
        persistRecord()
    }

    public var hasAccess: Bool { state.grantsAccess }

    public var licenseKey: String? { record?.licenseKey }

    public var trialDaysRemaining: Int? { record?.trialDaysRemaining }

    public func start() {
        guard isEnabled else { return }
        Task { await synchronizeAccessState() }
    }

    public func activate(licenseKey: String) async {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, record != nil else {
            lastError = .licenseKeyRequired
            return
        }

        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let licenseToken = try await client.activate(
                licenseKey: key,
                deviceID: deviceID,
                deviceName: deviceName,
                deviceProfile: .current
            )
            let validationDate = effectiveNow()
            self.record?.licenseKey = key
            self.record?.licenseIsValid = true
            self.record?.invalidReason = nil
            self.record?.lastValidatedAt = validationDate
            if let licenseToken {
                self.record?.licenseToken = licenseToken
            }
            persistRecord()
            refreshState()
        } catch {
            lastError = Self.error(for: error)
        }
    }

    /// Imports a signed offline license token exported for this device —
    /// e.g. a hand-signed token sent by the developer if the license server
    /// is ever permanently shut down. Verified fully offline against the
    /// public key embedded in the app; no network call is made.
    public func importLicenseToken(_ token: String) {
        guard record != nil else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let payload = try OfflineLicenseToken.verify(
                token,
                deviceID: deviceID,
                now: effectiveNow(),
                publicKeyRaw: offlineTokenPublicKeyRaw
            )
            lastError = nil
            self.record?.licenseKey = payload.licenseKey
            self.record?.licenseIsValid = nil
            self.record?.invalidReason = nil
            self.record?.lastValidatedAt = nil
            self.record?.licenseToken = token
            persistRecord()
            refreshState()
        } catch let error as OfflineLicenseTokenError {
            lastError = Self.error(forImportError: error)
        } catch {
            lastError = .importInvalid
        }
    }

    public func validate(force: Bool = false) async {
        guard let record, let key = record.licenseKey else { return }
        guard force || validationIsDue else { return }

        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let result = try await client.validate(licenseKey: key, deviceID: deviceID)
            let validationDate = effectiveNow()
            self.record?.lastValidatedAt = validationDate
            switch result {
            case .success(let licenseToken):
                self.record?.licenseIsValid = true
                self.record?.invalidReason = nil
                if let licenseToken {
                    self.record?.licenseToken = licenseToken
                }
            case .failure(let reason):
                self.record?.licenseIsValid = false
                self.record?.invalidReason = reason
            }
            persistRecord()
            refreshState()
        } catch {
            // A transport or server outage never revokes a previously valid
            // perpetual license. The next launch will retry validation.
            lastError = .validationUnavailable
        }
    }

    public func deactivate() async {
        guard let record, let key = record.licenseKey else { return }

        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            try await client.deactivate(licenseKey: key, deviceID: deviceID)
            self.record?.licenseKey = nil
            self.record?.licenseIsValid = nil
            self.record?.invalidReason = nil
            self.record?.lastValidatedAt = nil
            self.record?.licenseToken = nil
            persistRecord()
            await synchronizeTrialState()
        } catch {
            lastError = Self.error(for: error)
        }
    }

    public func refreshState() {
        guard isEnabled, let record else { return }
        state = Self.state(
            for: record,
            deviceID: deviceID,
            now: effectiveNow(),
            offlineTokenPublicKeyRaw: offlineTokenPublicKeyRaw
        )
        scheduleTrialRefreshIfNeeded()
    }

    private var validationIsDue: Bool {
        guard record?.licenseToken != nil else { return true }
        guard let lastValidatedAt = record?.lastValidatedAt else { return true }
        let currentDate = now()
        guard lastValidatedAt <= currentDate else { return true }
        return currentDate.timeIntervalSince(lastValidatedAt) >= Self.validationInterval
    }

    private func effectiveNow() -> Date {
        let currentDate = now()
        guard let lastObservedAt = record?.lastObservedAt else { return currentDate }
        return max(currentDate, lastObservedAt)
    }

    private static func state(
        for record: LicenseRecord,
        deviceID: String,
        now: Date,
        offlineTokenPublicKeyRaw: Data
    ) -> LicenseAccessState {
        if record.licenseKey != nil {
            switch record.licenseIsValid {
            case true:
                guard let licenseToken = record.licenseToken else {
                    return .invalid(.unknown)
                }
                return offlineTokenGrantsAccess(
                    licenseToken,
                    deviceID: deviceID,
                    now: now,
                    publicKeyRaw: offlineTokenPublicKeyRaw
                ) ? .licensed : .invalid(.unknown)
            case false:
                return .invalid(record.invalidReason ?? .unknown)
            case nil:
                // Never confirmed over the network (e.g. a manually imported
                // token) — the cached offline token is the only proof we
                // have, so it alone decides access.
                if let licenseToken = record.licenseToken,
                   offlineTokenGrantsAccess(
                       licenseToken,
                       deviceID: deviceID,
                       now: now,
                       publicKeyRaw: offlineTokenPublicKeyRaw
                   ) {
                    return .licensed
                }
                return .invalid(.unknown)
            }
        }
        // A server-confirmed expiry always wins; otherwise a still-valid
        // signed trial token is proof enough on its own — whether it was
        // just confirmed this session (`trialIsValid == true`) or cached
        // from an earlier launch that hasn't checked in yet (`nil`) — exactly
        // like a license's offline token in the branch above.
        if record.trialIsValid == false {
            return .trialExpired
        }
        if let trialToken = record.trialToken,
           offlineTokenGrantsAccess(
               trialToken,
               deviceID: deviceID,
               now: now,
               publicKeyRaw: offlineTokenPublicKeyRaw
           ) {
            return .trial
        }
        return .trialUnverified
    }

    private static func offlineTokenGrantsAccess(
        _ token: String,
        deviceID: String,
        now: Date,
        publicKeyRaw: Data
    ) -> Bool {
        (try? OfflineLicenseToken.verify(
            token,
            deviceID: deviceID,
            now: now,
            publicKeyRaw: publicKeyRaw
        )) != nil
    }

    private func synchronizeAccessState() async {
        guard isEnabled, let record else { return }
        if record.licenseKey != nil {
            if validationIsDue {
                await validate(force: true)
            }
            return
        }
        await synchronizeTrialState()
    }

    private func synchronizeTrialState() async {
        guard isEnabled, let record, record.licenseKey == nil else { return }
        do {
            if record.trialLastCheckedAt == nil {
                try await client.startTrial(
                    deviceID: deviceID,
                    product: productID,
                    deviceName: deviceName,
                    deviceProfile: .current
                )
            }
            let result = try await client.trialStatus(deviceID: deviceID, product: productID)
            let checkDate = effectiveNow()
            self.record?.trialLastCheckedAt = checkDate
            switch result {
            case .success(let status):
                self.record?.trialIsValid = true
                self.record?.trialDaysRemaining = status.daysRemaining
                self.record?.trialToken = status.trialToken
            case .failure:
                self.record?.trialIsValid = false
                self.record?.trialDaysRemaining = nil
                self.record?.trialToken = nil
            }
            persistRecord()
            refreshState()
        } catch {
            // A transport or server outage never revokes a previously
            // verified trial: the cached signed trial token (if any) keeps
            // deciding access on its own, exactly like a paid license's
            // offline token. `scheduleTrialRefreshIfNeeded` (invoked by
            // `refreshState` below) keeps retrying so a temporary outage
            // doesn't strand an unverified trial denied forever once
            // connectivity returns.
            refreshState()
            lastError = lastError ?? .serverUnavailable
        }
    }

    private func scheduleTrialRefreshIfNeeded() {
        trialSyncTimer?.invalidate()
        trialSyncTimer = nil
        guard isEnabled,
              record?.licenseKey == nil,
              // Keep retrying as long as the trial hasn't been definitively
              // confirmed expired — including while merely unverified, so a
              // temporary network outage doesn't strand the user denied
              // forever once connectivity returns.
              record?.trialIsValid != false else { return }
        trialSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.trialSyncInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.synchronizeTrialState()
            }
        }
    }

    private func persistRecord() {
        guard var record else { return }
        record.lastObservedAt = max(now(), record.lastObservedAt)
        self.record = record
        do {
            try secureStore.save(record)
        } catch {
            lastError = Self.storageError(for: error, appName: appName)
        }
    }

    private static func storageError(for error: Error, appName: String) -> LicenseManagerError {
        let code = (error as? KeychainLicenseStore.KeychainError).map { Int($0.status) }
            ?? (error as NSError).code
        return .storage(statusCode: code, appName: appName)
    }

    private static func error(for error: Error) -> LicenseManagerError {
        if let apiError = error as? LicenseAPIError {
            return .server(apiError)
        }
        return .serverUnavailable
    }

    private static func error(forImportError error: OfflineLicenseTokenError) -> LicenseManagerError {
        switch error {
        case .deviceMismatch:
            .importDeviceMismatch
        case .expired:
            .importExpired
        case .malformed, .invalidSignature:
            .importInvalid
        }
    }
}
