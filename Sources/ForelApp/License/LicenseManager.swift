import AppKit
import Foundation
import Combine
import ForelCore

@MainActor
final class LicenseManager: ObservableObject {
    static let validationInterval: TimeInterval = 24 * 60 * 60
    static let trialSyncInterval = validationInterval
    private static let trialProduct = "forel"

    @Published private(set) var state: LicenseAccessState
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let capabilities: BuildCapabilities
    private let secureStore: LicenseSecureStoring
    private let client: any LicenseAPIClientProtocol
    private let now: () -> Date
    private let offlineTokenPublicKeyRaw: Data
    private let deviceID: String
    private var record: LicenseRecord?
    private var trialSyncTimer: Timer?

    init(
        capabilities: BuildCapabilities = .current,
        secureStore: LicenseSecureStoring = KeychainLicenseStore(),
        client: any LicenseAPIClientProtocol = LicenseAPIClient(),
        deviceIdentifierProvider: any DeviceIdentifierProviding = HardwareDeviceIdentifierProvider(),
        now: @escaping () -> Date = Date.init,
        offlineTokenPublicKeyRaw: Data = OfflineLicenseToken.productionPublicKeyRaw
    ) {
        self.capabilities = capabilities
        self.secureStore = secureStore
        self.client = client
        self.now = now
        self.offlineTokenPublicKeyRaw = offlineTokenPublicKeyRaw
        self.deviceID = deviceIdentifierProvider.deviceID

        guard capabilities.usesDirectLicensing else {
            state = .bypassed
            return
        }

        let currentDate = now()
        do {
            record = try secureStore.load() ?? LicenseRecord(lastObservedAt: currentDate)
        } catch {
            record = LicenseRecord(lastObservedAt: currentDate)
            errorMessage = Self.storageErrorMessage(for: error)
        }

        let persistedState = Self.state(
            for: record!,
            deviceID: deviceID,
            now: currentDate,
            offlineTokenPublicKeyRaw: offlineTokenPublicKeyRaw
        )
        state = persistedState
        persistRecord()
    }

    var hasAccess: Bool { state.grantsAccess }

    var licenseKey: String? { record?.licenseKey }

    var trialDaysRemaining: Int? { record?.trialDaysRemaining }

    var deviceName: String {
        Host.current().localizedName ?? "This Mac"
    }

    func start() {
        guard capabilities.usesDirectLicensing else { return }
        Task { await synchronizeAccessState() }
    }

    func activate(licenseKey: String) async {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, record != nil else {
            errorMessage = "A license key is required."
            return
        }

        isWorking = true
        errorMessage = nil
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
            errorMessage = message(for: error)
        }
    }

    func importLicenseToken(_ token: String) {
        guard record != nil else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let payload = try OfflineLicenseToken.verify(
                token,
                deviceID: deviceID,
                now: effectiveNow(),
                publicKeyRaw: offlineTokenPublicKeyRaw
            )
            errorMessage = nil
            self.record?.licenseKey = payload.licenseKey
            self.record?.licenseIsValid = nil
            self.record?.invalidReason = nil
            self.record?.lastValidatedAt = nil
            self.record?.licenseToken = token
            persistRecord()
            refreshState()
        } catch let error as OfflineLicenseTokenError {
            errorMessage = message(forImportError: error)
        } catch {
            errorMessage = "The imported license file is invalid."
        }
    }

    func validate(force: Bool = false) async {
        guard let record, let key = record.licenseKey else { return }
        guard force || validationIsDue else { return }

        isWorking = true
        errorMessage = nil
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
            errorMessage = "License validation is temporarily unavailable."
        }
    }

    func deactivate() async {
        guard let record, let key = record.licenseKey else { return }

        isWorking = true
        errorMessage = nil
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
            errorMessage = message(for: error)
        }
    }

    func refreshState() {
        guard capabilities.usesDirectLicensing,
              let record else { return }
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
        guard capabilities.usesDirectLicensing,
              let record else { return }
        if record.licenseKey != nil {
            if validationIsDue {
                await validate(force: true)
            }
            return
        }
        await synchronizeTrialState()
    }

    private func synchronizeTrialState() async {
        guard capabilities.usesDirectLicensing,
              let record,
              record.licenseKey == nil else { return }
        do {
            if record.trialLastCheckedAt == nil {
                try await client.startTrial(
                    deviceID: deviceID,
                    product: Self.trialProduct,
                    deviceName: deviceName,
                    deviceProfile: .current
                )
            }
            let result = try await client.trialStatus(deviceID: deviceID, product: Self.trialProduct)
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
            refreshState()
            errorMessage = errorMessage ?? "The license server is unavailable."
        }
    }

    private func scheduleTrialRefreshIfNeeded() {
        trialSyncTimer?.invalidate()
        trialSyncTimer = nil
        guard capabilities.usesDirectLicensing,
              record?.licenseKey == nil,
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
            errorMessage = Self.storageErrorMessage(for: error)
        }
    }

    private static func storageErrorMessage(for error: Error) -> String {
        let code = (error as? KeychainLicenseStore.KeychainError).map { Int($0.status) }
            ?? (error as NSError).code
        return "License storage error (code \(code))."
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? LicenseAPIError {
            return apiError.message
        }
        return "The license server is unavailable."
    }

    private func message(forImportError error: OfflineLicenseTokenError) -> String {
        switch error {
        case .deviceMismatch: "This license was issued for a different Mac."
        case .expired: "This license has expired."
        case .malformed, .invalidSignature: "The license file is invalid."
        }
    }
}
