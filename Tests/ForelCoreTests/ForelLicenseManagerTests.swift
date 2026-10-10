import CryptoKit
import Foundation
import Lab421Licensing
import Testing
@testable import ForelCore

@Suite @MainActor struct ForelLicenseManagerTests {
    @Test func freeWorksWithoutContactingTheServer() async {
        let client = PaidClient()
        let manager = manager(store: Store(), client: client)
        manager.start()
        await Task.yield()
        #expect(manager.state == .free)
        #expect(await client.calls == 0)
    }

    @Test func freeRestartSkipsKeychainAndProStillRestoresOffline() async throws {
        let suite = "com.lab421.forel.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backing = Store()
        var startupReadsDenied = false
        func secureStore() -> ForelKeychainLicenseStore {
            ForelKeychainLicenseStore(service: "test", defaults: defaults, secureStore: backing) {
                if startupReadsDenied { throw URLError(.userAuthenticationRequired) }
                return try backing.load()
            }
        }
        let key = Curve25519.Signing.PrivateKey()
        let client = PaidClient(token: try token(key: key))
        let free = manager(store: secureStore(), client: client, publicKey: key.publicKey.rawRepresentation)
        #expect(free.state == .free)
        #expect(backing.loads == 1)
        let restartedFree = manager(store: secureStore(), client: client, publicKey: key.publicKey.rawRepresentation)
        restartedFree.start()
        await Task.yield()
        #expect(restartedFree.state == .free)
        #expect(backing.loads == 1)
        #expect(await client.calls == 0)
        await restartedFree.activate(licenseKey: "PRO-KEY")
        #expect(restartedFree.state == .pro)
        // A new local signature cannot read silently, but a previously
        // activated license must still restore with authorization, offline.
        startupReadsDenied = true
        await client.setUnavailable()
        let restartedPro = manager(store: secureStore(), client: client, publicKey: key.publicKey.rawRepresentation)
        #expect(restartedPro.state == .pro)
        #expect(restartedPro.lastError == nil)
        #expect(backing.loads == 2)
        await client.setValid()
        await restartedPro.deactivate()
        let reads = backing.loads
        #expect(manager(store: secureStore(), client: client).state == .free)
        #expect(backing.loads == reads)
    }

    @Test func activationOfflineUseRevocationAndDeactivation() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = Store()
        let client = PaidClient(token: try token(key: key))
        let manager = manager(store: store, client: client, publicKey: key.publicKey.rawRepresentation)
        await manager.activate(licenseKey: "PRO-KEY")
        #expect(manager.state == .pro)
        #expect(store.record?.licenseToken != nil)
        let restarted = self.manager(store: store, client: client, publicKey: key.publicKey.rawRepresentation)
        #expect(restarted.state == .pro)
        await client.setUnavailable()
        await restarted.validate()
        #expect(restarted.state == .pro)
        await client.setRevoked()
        await restarted.validate()
        #expect(restarted.state == .free)
        #expect(self.manager(store: store, client: client, publicKey: key.publicKey.rawRepresentation).state == .free)
        await client.setValid()
        await restarted.activate(licenseKey: "PRO-KEY")
        await restarted.deactivate()
        #expect(restarted.state == .free)
        #expect(store.record?.licenseKey == nil)
    }

    @Test(arguments: ["other-product", "missing-key", "other-device", "expired"])
    func rejectsSignedTokensWithoutForelProRights(kind: String) async throws {
        let key = Curve25519.Signing.PrivateKey()
        let client = PaidClient(token: try token(key: key, kind: kind))
        let manager = manager(store: Store(), client: client, publicKey: key.publicKey.rawRepresentation)
        await manager.activate(licenseKey: "PRO-KEY")
        #expect(manager.state == .free)
        #expect(manager.lastError != nil)
    }

    private func manager(store: any LicenseSecureStoring, client: PaidClient, publicKey: Data = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) -> ForelLicenseManager {
        ForelLicenseManager(isEnabled: true, productID: "forel", appName: "Forel", deviceNameFallback: "Mac", secureStore: store,
                            deviceIdentifierProvider: Device(), offlineTokenPublicKeyRaw: publicKey,
                            baseURL: URL(string: "http://localhost:8787/api/v1/license")!, client: client)
    }

    private func token(key: Curve25519.Signing.PrivateKey, kind: String = "valid") throws -> String {
        var payload: [String: Any] = ["product_id": kind == "other-product" ? "other" : "forel",
                                      "device_id": kind == "other-device" ? "other" : "device"]
        if kind != "missing-key" { payload["license_key"] = "PRO-KEY" }
        if kind == "expired" { payload["valid_until"] = "2020-01-01T00:00:00.000Z" }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return data.base64EncodedString() + "." + (try key.signature(for: data)).base64EncodedString()
    }
}

@MainActor private final class Store: LicenseSecureStoring {
    var record: LicenseRecord?
    var loads = 0
    func load() throws -> LicenseRecord? { loads += 1; return record }
    func save(_ record: LicenseRecord) throws { self.record = record }
}
private struct Device: DeviceIdentifierProviding { let deviceID = "device" }
private actor PaidClient: LicenseAPIClientProtocol {
    var calls = 0
    var unavailable = false
    var revoked = false
    let token: String?
    init(token: String? = nil) { self.token = token }
    func setUnavailable() { unavailable = true }
    func setRevoked() { unavailable = false; revoked = true }
    func setValid() { unavailable = false; revoked = false }
    func activate(licenseKey: String, deviceID: String, deviceName: String?, deviceProfile: DeviceProfile?) async throws -> String? { calls += 1; return token }
    func validate(licenseKey: String, deviceID: String) async throws -> Result<String?, LicenseInvalidReason> {
        calls += 1
        if unavailable { throw URLError(.notConnectedToInternet) }
        return revoked ? .failure(.licenseDisabled) : .success(token)
    }
    func deactivate(licenseKey: String, deviceID: String) async throws { calls += 1 }
    func startTrial(deviceID: String, product: String, deviceName: String?, deviceProfile: DeviceProfile?) async throws {
        Issue.record("Free must not register an evaluation period")
    }
    func trialStatus(deviceID: String, product: String) async throws -> Result<TrialStatus, TrialInvalidReason> {
        Issue.record("Free must not request an evaluation period")
        return .failure(.unknown)
    }
}
