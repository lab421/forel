import CryptoKit
import Foundation

public enum OfflineLicenseToken {
    public static let productionPublicKeyRaw = Data(
        base64Encoded: "U0CobIap9nWvOjGXe0Xg8jY37k86j1l2bJTny4GYsNI="
    )!

    public static func verify(
        _ token: String,
        deviceID: String,
        now: Date,
        publicKeyRaw: Data = productionPublicKeyRaw
    ) throws -> OfflineLicensePayload {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Data(base64URLEncoded: String(parts[0])),
              let signatureData = Data(base64URLEncoded: String(parts[1])) else {
            throw OfflineLicenseTokenError.malformed
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw OfflineLicenseTokenError.invalidSignature
        }

        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let payloadDeviceID = json["device_id"] as? String,
              let productID = json["product_id"] as? String else {
            throw OfflineLicenseTokenError.malformed
        }
        let licenseKey = json["license_key"] as? String

        guard payloadDeviceID == deviceID else {
            throw OfflineLicenseTokenError.deviceMismatch
        }

        var validUntil: Date?
        if let raw = json["valid_until"], !(raw is NSNull) {
            guard let validUntilString = raw as? String,
                  let parsed = Self.dateFormatter().date(from: validUntilString) else {
                throw OfflineLicenseTokenError.malformed
            }
            validUntil = parsed
        }

        if let validUntil, now >= validUntil {
            throw OfflineLicenseTokenError.expired
        }

        return OfflineLicensePayload(
            licenseKey: licenseKey,
            deviceID: payloadDeviceID,
            productID: productID,
            validUntil: validUntil
        )
    }
}

private extension OfflineLicenseToken {
    static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        self.init(base64Encoded: base64)
    }
}
