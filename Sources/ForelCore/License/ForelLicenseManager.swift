import Combine
import Foundation
import Lab421Licensing

public enum ForelLicenseState: Equatable, Sendable {
    case free
    case pro
}

/// Paid-license access only. Free needs neither registration nor connectivity.
@MainActor
public final class ForelLicenseManager: ObservableObject {
    @Published public private(set) var state: ForelLicenseState = .free
    @Published public private(set) var isWorking = false
    @Published public private(set) var lastError: String?
    public var hasAccess: Bool { state == .pro }
    public var licenseKey: String? { record?.licenseKey }
    public let deviceName: String
    private let enabled: Bool
    private let productID: String
    private let deviceID: String
    private let publicKey: Data
    private let store: any LicenseSecureStoring
    private let client: any LicenseAPIClientProtocol
    private var record: LicenseRecord?
    private var refreshTimer: Timer?
    private var nextValidationAt = Date().addingTimeInterval(24 * 60 * 60)

    public init(isEnabled: Bool, productID: String, appName: String, deviceNameFallback: String,
                secureStore: any LicenseSecureStoring, deviceIdentifierProvider: any DeviceIdentifierProviding,
                offlineTokenPublicKeyRaw: Data, baseURL: URL, client: (any LicenseAPIClientProtocol)? = nil) {
        enabled = isEnabled
        self.productID = productID
        deviceID = deviceIdentifierProvider.deviceID
        deviceName = Host.current().localizedName ?? deviceNameFallback
        publicKey = offlineTokenPublicKeyRaw
        store = secureStore
        self.client = client ?? LicenseAPIClient(baseURL: baseURL)
        guard enabled else { return }
        do { record = try store.load() } catch { lastError = L10n.string("license_error_could_read_saved_license", error.localizedDescription) }
        refreshState()
    }

    public func start() {
        guard enabled, record?.licenseKey != nil else { return }
        Task { await validate() }
    }

    private func accepts(_ token: String, key: String) -> Bool {
        guard let payload = try? OfflineLicenseToken.verify(token, deviceID: deviceID, now: Date(), publicKeyRaw: publicKey) else { return false }
        return payload.productID == productID && payload.licenseKey == key && !key.isEmpty
    }

    private func refreshState() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let record, record.licenseIsValid != false, let key = record.licenseKey,
              let token = record.licenseToken, accepts(token, key: key) else { state = .free; return }
        state = .pro
        // Recheck signed expiry while the app stays open. Network validation
        // is occasional and never required for the Free plan.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshState()
                if self.state == .pro, Date() >= self.nextValidationAt {
                    await self.validate()
                }
            }
        }
    }

    public func activate(licenseKey: String) async {
        guard enabled, !isWorking else { return }
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { lastError = L10n.string("license_error_enter_license_key_activate"); return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            guard let token = try await client.activate(licenseKey: key, deviceID: deviceID, deviceName: deviceName, deviceProfile: nil),
                  accepts(token, key: key) else { lastError = L10n.string("license_error_server_did_return_valid"); return }
            let next = LicenseRecord(lastObservedAt: Date(), licenseKey: key, licenseIsValid: true, lastValidatedAt: Date(), licenseToken: token)
            try store.save(next)
            record = next
            refreshState()
        } catch { lastError = L10n.string("license_error_could_activate_forel_pro", error.localizedDescription) }
    }

    public func validate() async {
        guard enabled, !isWorking, let key = record?.licenseKey else { return }
        nextValidationAt = Date().addingTimeInterval(24 * 60 * 60)
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await client.validate(licenseKey: key, deviceID: deviceID) {
            case .success(let token):
                guard let token, accepts(token, key: key) else { lastError = L10n.string("license_error_server_did_return_valid"); return }
                let next = LicenseRecord(lastObservedAt: Date(), licenseKey: key, licenseIsValid: true, lastValidatedAt: Date(), licenseToken: token)
                try store.save(next)
                record = next
                lastError = nil
            case .failure:
                record?.licenseIsValid = false
                refreshState()
                if let record { try store.save(record) }
                lastError = L10n.string("license_error_license_longer_valid_forel")
            }
            refreshState()
        } catch {
            refreshState()
            lastError = L10n.string("license_error_could_verify_license_valid")
        }
    }

    public func deactivate() async {
        guard enabled, !isWorking, let key = record?.licenseKey else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.deactivate(licenseKey: key, deviceID: deviceID)
            record?.licenseIsValid = false
            state = .free
            refreshTimer?.invalidate()
            refreshTimer = nil
            try store.save(LicenseRecord(lastObservedAt: Date()))
            record = nil
            lastError = nil
        } catch { lastError = L10n.string("license_error_could_finish_deactivating_license", error.localizedDescription) }
    }
}
