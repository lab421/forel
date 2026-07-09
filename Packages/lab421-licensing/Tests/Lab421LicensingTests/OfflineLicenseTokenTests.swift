import CryptoKit
import Foundation
import Testing
@testable import Lab421Licensing

struct OfflineLicenseTokenTests {
    @Test func verifiesAValidTokenWithNoExpiry() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = signedToken(
            privateKey: privateKey,
            licenseKey: "ABCD-1234",
            deviceID: "device-1"
        )

        let payload = try OfflineLicenseToken.verify(
            token,
            deviceID: "device-1",
            now: Date(),
            publicKeyRaw: privateKey.publicKey.rawRepresentation
        )

        #expect(payload.licenseKey == "ABCD-1234")
        #expect(payload.deviceID == "device-1")
        #expect(payload.productID == "ombrelle")
        #expect(payload.validUntil == nil)
    }

    @Test func rejectsATokenSignedByAnotherKey() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let token = signedToken(privateKey: privateKey, licenseKey: "ABCD", deviceID: "device-1")

        #expect(throws: OfflineLicenseTokenError.invalidSignature) {
            try OfflineLicenseToken.verify(
                token,
                deviceID: "device-1",
                now: Date(),
                publicKeyRaw: otherKey.publicKey.rawRepresentation
            )
        }
    }

    @Test func rejectsATokenForADifferentDevice() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = signedToken(privateKey: privateKey, licenseKey: "ABCD", deviceID: "device-1")

        #expect(throws: OfflineLicenseTokenError.deviceMismatch) {
            try OfflineLicenseToken.verify(
                token,
                deviceID: "device-2",
                now: Date(),
                publicKeyRaw: privateKey.publicKey.rawRepresentation
            )
        }
    }

    @Test func rejectsATokenPastItsValidUntilDate() {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validUntil = Date(timeIntervalSince1970: 1_700_000_000)
        let token = signedToken(
            privateKey: privateKey,
            licenseKey: "ABCD",
            deviceID: "device-1",
            validUntil: validUntil
        )

        #expect(throws: OfflineLicenseTokenError.expired) {
            try OfflineLicenseToken.verify(
                token,
                deviceID: "device-1",
                now: validUntil.addingTimeInterval(1),
                publicKeyRaw: privateKey.publicKey.rawRepresentation
            )
        }
    }

    @Test func acceptsATokenBeforeItsValidUntilDate() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validUntil = Date(timeIntervalSince1970: 1_700_000_000)
        let token = signedToken(
            privateKey: privateKey,
            licenseKey: "ABCD",
            deviceID: "device-1",
            validUntil: validUntil
        )

        let payload = try OfflineLicenseToken.verify(
            token,
            deviceID: "device-1",
            now: validUntil.addingTimeInterval(-1),
            publicKeyRaw: privateKey.publicKey.rawRepresentation
        )
        #expect(payload.validUntil == validUntil)
    }

    @Test func verifiesATrialTokenWithNoLicenseKey() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validUntil = Date(timeIntervalSince1970: 1_700_000_000)
        let token = signedToken(
            privateKey: privateKey,
            deviceID: "device-1",
            validUntil: validUntil
        )

        let payload = try OfflineLicenseToken.verify(
            token,
            deviceID: "device-1",
            now: validUntil.addingTimeInterval(-1),
            publicKeyRaw: privateKey.publicKey.rawRepresentation
        )

        #expect(payload.licenseKey == nil)
        #expect(payload.deviceID == "device-1")
        #expect(payload.validUntil == validUntil)
    }

    @Test func rejectsAMalformedToken() {
        let privateKey = Curve25519.Signing.PrivateKey()

        #expect(throws: OfflineLicenseTokenError.malformed) {
            try OfflineLicenseToken.verify(
                "not-a-token",
                deviceID: "device-1",
                now: Date(),
                publicKeyRaw: privateKey.publicKey.rawRepresentation
            )
        }
    }
}

func signedToken(
    privateKey: Curve25519.Signing.PrivateKey,
    licenseKey: String? = nil,
    deviceID: String,
    productID: String = "ombrelle",
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
