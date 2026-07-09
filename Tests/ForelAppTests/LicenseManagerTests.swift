// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import CryptoKit
import Foundation
import Testing
import ForelCore
@testable import ForelApp

@MainActor
struct LicenseManagerTests {
    @Test func activateCachesLicenseTokenAndGrantsAccessAfterANetworkOutage() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        let privateKey = Curve25519.Signing.PrivateKey()
        await client.setActivationLicenseToken(
            signedToken(privateKey: privateKey, licenseKey: "TEST-KEY", deviceID: "hardware-fingerprint")
        )
        let manager = makeManager(store: store, client: client, clock: clock, publicKey: privateKey.publicKey)

        await manager.activate(licenseKey: "TEST-KEY")
        #expect(manager.state == .licensed)
        #expect(store.record?.licenseToken != nil)

        // Simulate a fresh launch that can no longer reach the network at
        // all: the manager should still grant access purely from the
        // cached, cryptographically-verified offline token.
        let record = store.record!
        let offlineOnlyStore = MemoryLicenseStore(record: LicenseRecord(
            lastObservedAt: record.lastObservedAt,
            trialIsValid: nil,
            trialLastCheckedAt: nil,
            trialDaysRemaining: nil,
            licenseKey: record.licenseKey,
            licenseIsValid: nil,
            invalidReason: nil,
            lastValidatedAt: nil,
            licenseToken: record.licenseToken
        ))
        let offlineClient = MockLicenseClient()
        await offlineClient.setNetworkFailure(true)
        let offlineManager = makeManager(store: offlineOnlyStore, client: offlineClient, clock: clock, publicKey: privateKey.publicKey)

        #expect(offlineManager.state == .licensed)
        #expect(offlineManager.hasAccess)
    }

    @Test func keychainSaveFailureSurfacesAnActionableMessageWithTheErrorCode() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        store.saveError = KeychainLicenseStore.KeychainError(status: -25300)
        let manager = makeManager(store: store, clock: clock)

        await manager.activate(licenseKey: "TEST-KEY")

        #expect(manager.errorMessage?.contains("-25300") == true)
    }

    @Test func aRecordCopiedFromAnotherMacIsNotTrustedEvenWithLicenseIsValidTrue() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let privateKey = Curve25519.Signing.PrivateKey()
        // Simulates the whole Keychain item being copied verbatim from
        // another Mac: `licenseIsValid` says true, but the cached token was
        // signed for a different device_id than this one.
        let copiedRecord = LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: nil,
            trialLastCheckedAt: nil,
            trialDaysRemaining: nil,
            licenseKey: "TEST-KEY",
            licenseIsValid: true,
            invalidReason: nil,
            lastValidatedAt: clock.date,
            licenseToken: signedToken(
                privateKey: privateKey,
                licenseKey: "TEST-KEY",
                deviceID: "original-mac-device-id"
            )
        )
        let store = MemoryLicenseStore(record: copiedRecord)
        let manager = makeManager(store: store, clock: clock, publicKey: privateKey.publicKey)

        // The manager resolves this device's real ID as "hardware-fingerprint"
        // (see StaticDeviceIdentifierProvider below), which doesn't match the
        // token's "original-mac-device-id".
        #expect(manager.state == .invalid(.unknown))
        #expect(!manager.hasAccess)
    }

    @Test func cachedLicenseBooleanWithoutASignedTokenDoesNotGrantAccess() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            licenseKey: "FORGED-KEY",
            licenseIsValid: true,
            lastValidatedAt: Date.distantFuture
        )
        let manager = makeManager(
            store: MemoryLicenseStore(record: record),
            clock: clock
        )

        #expect(manager.state == .invalid(.unknown))
        #expect(!manager.hasAccess)
    }

    @Test func unconfirmedLicenseWithAnInvalidTokenIsExplicitlyDenied() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            licenseKey: "TEST-KEY",
            licenseIsValid: nil,
            licenseToken: "not-a-signed-token"
        )
        let manager = makeManager(
            store: MemoryLicenseStore(record: record),
            clock: clock
        )

        #expect(manager.state == .invalid(.unknown))
        #expect(!manager.hasAccess)
    }

    @Test func futureValidationDateWithoutATokenCannotSuppressServerValidation() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore(record: LicenseRecord(
            lastObservedAt: Date.distantFuture,
            licenseKey: "FORGED-KEY",
            licenseIsValid: true,
            lastValidatedAt: Date.distantFuture
        ))
        let client = MockLicenseClient()
        let manager = makeManager(store: store, client: client, clock: clock)

        manager.start()
        await waitUntil({
            await client.validationCount == 1
        }, timeout: 1.0)

        #expect(manager.state == .invalid(.unknown))
    }

    @Test func importLicenseTokenGrantsAccessWithoutEverReachingTheNetwork() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        await client.setNetworkFailure(true)
        let privateKey = Curve25519.Signing.PrivateKey()
        let manager = makeManager(store: store, client: client, clock: clock, publicKey: privateKey.publicKey)

        let token = signedToken(privateKey: privateKey, licenseKey: "HAND-SIGNED", deviceID: "hardware-fingerprint")
        manager.importLicenseToken(token)

        #expect(manager.state == .licensed)
        #expect(manager.hasAccess)
        #expect(store.record?.licenseKey == "HAND-SIGNED")
        #expect(manager.errorMessage == nil)
    }

    @Test func importLicenseTokenRejectsATokenIssuedForAnotherDevice() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        let privateKey = Curve25519.Signing.PrivateKey()
        let manager = makeManager(store: store, client: client, clock: clock, publicKey: privateKey.publicKey)

        let token = signedToken(privateKey: privateKey, licenseKey: "OTHER", deviceID: "some-other-mac")
        manager.importLicenseToken(token)

        #expect(manager.state == .trialUnverified)
        #expect(store.record?.licenseKey == nil)
        #expect(manager.errorMessage != nil)
    }

    @Test func trialStartAndStatusDriveAccess() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        let privateKey = Curve25519.Signing.PrivateKey()
        await client.setTrialStatus(.success(TrialStatus(
            daysRemaining: 5,
            expiresAt: clock.date.addingTimeInterval(5 * 86400),
            trialToken: signedToken(privateKey: privateKey, deviceID: "hardware-fingerprint")
        )))
        let manager = makeManager(store: store, client: client, clock: clock, publicKey: privateKey.publicKey)

        manager.start()
        await waitUntil({
            await client.trialStatusCount == 1 && manager.state == .trial
        }, timeout: 1.0)

        #expect(manager.hasAccess)
        #expect(await client.trialStartCount == 1)
        #expect(store.record?.trialIsValid == true)
        #expect(store.record?.trialToken != nil)
        #expect(manager.trialDaysRemaining == 5)
    }

    @Test func trialStatusValidWithoutASignedTokenDoesNotGrantAccess() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        // The server says the trial is valid but — unlike the fully-updated
        // API — returns no signed proof. Unlike a legacy trust in the raw
        // `valid` flag, this must not grant access.
        await client.setTrialStatus(.success(TrialStatus(
            daysRemaining: 5,
            expiresAt: clock.date.addingTimeInterval(5 * 86400),
            trialToken: nil
        )))
        let manager = makeManager(store: store, client: client, clock: clock)

        manager.start()
        await waitUntil({
            await client.trialStatusCount == 1
        }, timeout: 1.0)

        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)
    }

    @Test func trialTokenSignedByAnotherKeyDoesNotGrantAccess() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: true,
            trialLastCheckedAt: clock.date,
            trialDaysRemaining: 5,
            trialToken: signedToken(privateKey: otherKey, deviceID: "hardware-fingerprint")
        )
        let manager = makeManager(
            store: MemoryLicenseStore(record: record),
            clock: clock,
            publicKey: privateKey.publicKey
        )

        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)
    }

    @Test func trialTokenForADifferentDeviceDoesNotGrantAccess() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let privateKey = Curve25519.Signing.PrivateKey()
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: true,
            trialLastCheckedAt: clock.date,
            trialDaysRemaining: 5,
            // Signed for a different Mac than the one resolved by
            // `StaticDeviceIdentifierProvider` below ("hardware-fingerprint").
            trialToken: signedToken(privateKey: privateKey, deviceID: "some-other-mac")
        )
        let manager = makeManager(
            store: MemoryLicenseStore(record: record),
            clock: clock,
            publicKey: privateKey.publicKey
        )

        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)
    }

    @Test func expiredTrialTokenDoesNotGrantAccess() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let privateKey = Curve25519.Signing.PrivateKey()
        let validUntil = Date(timeIntervalSince1970: 1_700_000_000)
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: true,
            trialLastCheckedAt: clock.date,
            trialDaysRemaining: 0,
            trialToken: signedToken(
                privateKey: privateKey,
                deviceID: "hardware-fingerprint",
                validUntil: validUntil
            )
        )
        let manager = makeManager(
            store: MemoryLicenseStore(record: record),
            clock: TestClock(validUntil.addingTimeInterval(1)),
            publicKey: privateKey.publicKey
        )

        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)
    }

    @Test func expiredTrialBlocksAccess() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        await client.setTrialStatus(.failure(.trialExpired))
        let manager = makeManager(store: store, client: client, clock: clock)

        manager.start()
        await waitUntil({
            await client.trialStatusCount == 1 && manager.state == .trialExpired
        }, timeout: 1.0)

        #expect(!manager.hasAccess)
        #expect(store.record?.trialIsValid == false)
    }

    @Test func newInstallWithNoNetworkStartsDeniedNotOpen() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        await client.setNetworkFailure(true)
        let manager = makeManager(store: store, client: client, clock: clock)

        // Before any successful server check, a fresh trial must not
        // default to granting access.
        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)
        // But it's not a *confirmed* denial either — callers that only want
        // to interrupt the user for a definitive answer (e.g. forcing the
        // license window open at launch) must not treat it as one, or it
        // would fire on every single fresh launch while the check is still
        // in flight.
        #expect(!manager.state.isDefinitivelyDenied)
    }

    @Test func trialExpiredIsDefinitivelyDeniedButUnverifiedIsNot() {
        #expect(LicenseAccessState.trialExpired.isDefinitivelyDenied)
        #expect(LicenseAccessState.invalid(.licenseDisabled).isDefinitivelyDenied)
        #expect(!LicenseAccessState.trialUnverified.isDefinitivelyDenied)
        #expect(!LicenseAccessState.trial.isDefinitivelyDenied)
        #expect(!LicenseAccessState.licensed.isDefinitivelyDenied)
        #expect(!LicenseAccessState.bypassed.isDefinitivelyDenied)
    }

    @Test func cachedTrialBooleanWithoutASignedTokenDoesNotGrantAccess() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: true,
            trialLastCheckedAt: clock.date,
            trialDaysRemaining: 3
        )
        let store = MemoryLicenseStore(record: record)
        let client = MockLicenseClient()
        await client.setNetworkFailure(true)
        let manager = makeManager(store: store, client: client, clock: clock)

        // `trialIsValid` alone (display data from a previous check) is not
        // proof — without a signed trial token to back it up, access stays
        // denied, exactly like an unconfirmed license without an offline
        // token.
        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)

        manager.start()
        await waitUntil({
            await client.trialStatusCount == 1
        }, timeout: 1.0)

        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)
    }

    @Test func networkFailureKeepsPreviouslyValidatedTrialActive() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let privateKey = Curve25519.Signing.PrivateKey()
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: true,
            trialLastCheckedAt: clock.date,
            trialDaysRemaining: 3,
            trialToken: signedToken(privateKey: privateKey, deviceID: "hardware-fingerprint")
        )
        let store = MemoryLicenseStore(record: record)
        let client = MockLicenseClient()
        await client.setNetworkFailure(true)
        let manager = makeManager(store: store, client: client, clock: clock, publicKey: privateKey.publicKey)

        #expect(manager.state == .trial)
        #expect(manager.hasAccess)

        // A transport outage during the periodic re-check must not revoke a
        // trial whose cached signed token is still valid — exactly like a
        // license's offline token surviving a failed `/validate` call.
        manager.start()
        await waitUntil({
            await client.trialStatusCount == 1
        }, timeout: 1.0)

        #expect(manager.state == .trial)
        #expect(manager.hasAccess)
        #expect(manager.errorMessage != nil)
    }

    @Test func cachedTrialOnlyGrantsAccessAfterStartupVerificationSucceeds() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore(record: LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: true,
            trialLastCheckedAt: clock.date,
            trialDaysRemaining: 3
        ))
        let client = MockLicenseClient()
        let privateKey = Curve25519.Signing.PrivateKey()
        await client.setTrialStatus(.success(TrialStatus(
            daysRemaining: 2,
            expiresAt: clock.date.addingTimeInterval(2 * 86400),
            trialToken: signedToken(privateKey: privateKey, deviceID: "hardware-fingerprint")
        )))
        let manager = makeManager(store: store, client: client, clock: clock, publicKey: privateKey.publicKey)

        // No signed token cached yet from before this launch — denied until
        // this launch's own round-trip resolves it.
        #expect(manager.state == .trialUnverified)
        #expect(!manager.hasAccess)

        manager.start()
        await waitUntil({
            await client.trialStatusCount == 1 && manager.state == .trial
        }, timeout: 1.0)

        #expect(manager.hasAccess)
        #expect(manager.trialDaysRemaining == 2)
    }

    @Test func activationValidationAndDeactivationDriveAccess() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        let privateKey = Curve25519.Signing.PrivateKey()
        await client.setActivationLicenseToken(
            signedToken(
                privateKey: privateKey,
                licenseKey: "TEST-KEY",
                deviceID: "hardware-fingerprint"
            )
        )
        let manager = makeManager(
            store: store,
            client: client,
            clock: clock,
            publicKey: privateKey.publicKey
        )

        await manager.activate(licenseKey: "  TEST-KEY  ")
        #expect(manager.state == .licensed)
        #expect(store.record?.licenseKey == "TEST-KEY")

        clock.date.addTimeInterval(LicenseManager.validationInterval + 1)
        await client.setValidation(.failure(.deviceDeactivated))
        await manager.validate()
        #expect(manager.state == .invalid(.deviceDeactivated))
        #expect(!manager.hasAccess)

        await manager.activate(licenseKey: "TEST-KEY")
        await client.setTrialStatus(.success(TrialStatus(
            daysRemaining: 7,
            expiresAt: clock.date.addingTimeInterval(7 * 86400),
            trialToken: signedToken(privateKey: privateKey, deviceID: "hardware-fingerprint")
        )))
        await manager.deactivate()
        #expect(manager.state == .trial)
        #expect(store.record?.licenseKey == nil)
    }

    @Test func networkFailureKeepsPreviouslyValidatedLicenseActive() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let privateKey = Curve25519.Signing.PrivateKey()
        let record = LicenseRecord(
            lastObservedAt: clock.date,
            trialIsValid: true,
            trialLastCheckedAt: clock.date,
            trialDaysRemaining: nil,
            licenseKey: "TEST-KEY",
            licenseIsValid: true,
            invalidReason: nil,
            lastValidatedAt: clock.date,
            licenseToken: signedToken(
                privateKey: privateKey,
                licenseKey: "TEST-KEY",
                deviceID: "hardware-fingerprint"
            )
        )
        let store = MemoryLicenseStore(record: record)
        let client = MockLicenseClient()
        let manager = makeManager(
            store: store,
            client: client,
            clock: clock,
            publicKey: privateKey.publicKey
        )

        clock.date.addTimeInterval(LicenseManager.validationInterval + 1)
        await client.setNetworkFailure(true)
        await manager.validate()

        #expect(manager.state == .licensed)
        #expect(manager.hasAccess)
        #expect(manager.errorMessage != nil)
    }

    @Test func trialPeriodicRefreshUsesADailyInterval() {
        #expect(LicenseManager.trialSyncInterval == 24 * 60 * 60)
    }

    @Test func activationPersistsOnlyOnceAfterUpdatingTheClock() async {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = MemoryLicenseStore()
        let client = MockLicenseClient()
        let privateKey = Curve25519.Signing.PrivateKey()
        await client.setActivationLicenseToken(
            signedToken(
                privateKey: privateKey,
                licenseKey: "TEST-KEY",
                deviceID: "hardware-fingerprint"
            )
        )
        let manager = makeManager(
            store: store,
            client: client,
            clock: clock,
            publicKey: privateKey.publicKey
        )
        let savesAfterInitialization = store.saveCount
        clock.date.addTimeInterval(60)

        await manager.activate(licenseKey: "TEST-KEY")

        #expect(store.saveCount == savesAfterInitialization + 1)
    }

    @Test func nonDirectBuildBypassesLicensing() {
        let manager = LicenseManager(
            capabilities: BuildFlavor.appStore.capabilities,
            secureStore: MemoryLicenseStore(),
            client: MockLicenseClient()
        )

        #expect(manager.state == .bypassed)
        #expect(manager.hasAccess)
    }

    private func makeManager(
        store: MemoryLicenseStore,
        client: MockLicenseClient = MockLicenseClient(),
        clock: TestClock,
        publicKey: Curve25519.Signing.PublicKey = Curve25519.Signing.PrivateKey().publicKey
    ) -> LicenseManager {
        LicenseManager(
            capabilities: BuildFlavor.adHoc.capabilities,
            secureStore: store,
            client: client,
            deviceIdentifierProvider: StaticDeviceIdentifierProvider(deviceID: "hardware-fingerprint"),
            now: { clock.date },
            offlineTokenPublicKeyRaw: publicKey.rawRepresentation
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for condition")
    }
}

@MainActor
private final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor
private final class MemoryLicenseStore: LicenseSecureStoring {
    var record: LicenseRecord?
    var saveError: KeychainLicenseStore.KeychainError?
    private(set) var saveCount = 0

    init(record: LicenseRecord? = nil) {
        self.record = record
    }

    func load() throws -> LicenseRecord? { record }

    func save(_ record: LicenseRecord) throws {
        if let saveError { throw saveError }
        saveCount += 1
        self.record = record
    }
}

private actor MockLicenseClient: LicenseAPIClientProtocol {
    enum MockError: Error { case network }

    private var trialStatus: Result<TrialStatus, TrialInvalidReason> = .success(
        TrialStatus(daysRemaining: 7, expiresAt: Date(timeIntervalSince1970: 1_700_604_800), trialToken: nil)
    )
    private var validation: Result<String?, LicenseInvalidReason> = .success(nil)
    private var activationLicenseToken: String?
    private var networkFailure = false
    private(set) var trialStartCount = 0
    private(set) var trialStatusCount = 0
    private(set) var validationCount = 0

    func setTrialStatus(_ status: Result<TrialStatus, TrialInvalidReason>) {
        self.trialStatus = status
    }

    func setValidation(_ validation: Result<String?, LicenseInvalidReason>) {
        self.validation = validation
    }

    func setActivationLicenseToken(_ token: String?) {
        self.activationLicenseToken = token
    }

    func setNetworkFailure(_ networkFailure: Bool) {
        self.networkFailure = networkFailure
    }

    func startTrial(deviceID: String, product: String, deviceName: String?, deviceProfile: DeviceProfile?) async throws {
        if networkFailure { throw MockError.network }
        trialStartCount += 1
    }

    func trialStatus(deviceID: String, product: String) async throws -> Result<TrialStatus, TrialInvalidReason> {
        trialStatusCount += 1
        if networkFailure { throw MockError.network }
        return trialStatus
    }

    func activate(
        licenseKey: String,
        deviceID: String,
        deviceName: String?,
        deviceProfile: DeviceProfile?
    ) async throws -> String? {
        if networkFailure { throw MockError.network }
        return activationLicenseToken
    }

    func validate(licenseKey: String, deviceID: String) async throws -> Result<String?, LicenseInvalidReason> {
        if networkFailure { throw MockError.network }
        validationCount += 1
        return validation
    }

    func deactivate(licenseKey: String, deviceID: String) async throws {
        if networkFailure { throw MockError.network }
    }
}

private struct StaticDeviceIdentifierProvider: DeviceIdentifierProviding {
    let deviceID: String
}

/// Mints a `base64url(payload).base64url(signature)` offline token for tests
/// — the same wire format `OfflineLicenseToken.verify` expects. Duplicated
/// from `ForelCoreTests/License/OfflineLicenseTokenTests.swift` rather than
/// shared, since `ForelAppTests` and `ForelCoreTests` are separate test
/// targets.
private func signedToken(
    privateKey: Curve25519.Signing.PrivateKey,
    licenseKey: String? = nil,
    deviceID: String,
    productID: String = "forel",
    validUntil: Date? = nil
) -> String {
    var payload: [String: Any] = [
        "device_id": deviceID,
        "product_id": productID,
    ]
    if let licenseKey {
        payload["license_key"] = licenseKey
    }
    if let validUntil {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        payload["valid_until"] = formatter.string(from: validUntil)
    } else {
        payload["valid_until"] = NSNull()
    }
    let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let signature = try! privateKey.signature(for: payloadData)
    return base64URLEncode(payloadData) + "." + base64URLEncode(signature)
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
