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

import Foundation
import Testing
@testable import ForelCore

@Suite(.serialized)
struct LicenseAPIClientTests {
    @Test func endpointsSendExpectedJSONAndDecodeValidation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LicenseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = LicenseAPIClient(
            baseURL: URL(string: "https://example.test/api/v1/license")!,
            session: session
        )

        let testProfile = DeviceProfile(
            model: "MacBookPro18,1",
            cpu: "arm64",
            macosVersion: "14.5.0",
            cpuCount: 10,
            memoryMB: 16384,
            appVersion: "1.2.3",
            preferredLanguage: "en-GB"
        )

        LicenseURLProtocol.reset()
        try await client.startTrial(
            deviceID: "device-1",
            product: "forel",
            deviceName: "Mac Studio",
            deviceProfile: testProfile
        )
        let trialStart = try #require(LicenseURLProtocol.lastRequest)
        #expect(trialStart.url?.path == "/api/v1/trial/start")
        let trialStartBody = try #require(LicenseURLProtocol.lastJSONBody)
        #expect(trialStartBody["device_id"] as? String == "device-1")
        #expect(trialStartBody["product_id"] as? String == "forel")
        #expect(trialStartBody["device_name"] as? String == "Mac Studio")
        #expect(deviceProfileJSON(trialStartBody) == testProfile)

        LicenseURLProtocol.response =
            #"{"success":true,"valid":true,"expires_at":"2024-01-08T00:00:00.000Z","days_remaining":5,"trial_token":"trial-payload.trial-signature"}"#
        let trialStatus = try await client.trialStatus(deviceID: "device-1", product: "forel")
        switch trialStatus {
        case .success(let status):
            #expect(status.daysRemaining == 5)
            // The trial API signs its token under a different wire field
            // (`trial_token`) than the license API's `license_token` — this
            // guards against decoding the wrong one (they must not be
            // conflated into a single response field).
            #expect(status.trialToken == "trial-payload.trial-signature")
        case .failure:
            Issue.record("Expected trial status to be valid")
        }
        #expect(LicenseURLProtocol.lastRequest?.url?.path == "/api/v1/trial/status")
        let trialStatusBody = try #require(LicenseURLProtocol.lastJSONBody)
        #expect(trialStatusBody["device_id"] as? String == "device-1")
        #expect(trialStatusBody["product_id"] as? String == "forel")

        LicenseURLProtocol.response = #"{"success":true,"license_token":"payload.signature"}"#
        let licenseToken = try await client.activate(
            licenseKey: "ABC",
            deviceID: "device-1",
            deviceName: "Mac Studio",
            deviceProfile: testProfile
        )
        #expect(licenseToken == "payload.signature")
        let activation = try #require(LicenseURLProtocol.lastRequest)
        #expect(activation.url?.path == "/api/v1/license/activate")
        #expect(activation.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let activationBody = try #require(LicenseURLProtocol.lastJSONBody)
        #expect(activationBody["license_key"] as? String == "ABC")
        #expect(activationBody["device_id"] as? String == "device-1")
        #expect(activationBody["device_name"] as? String == "Mac Studio")
        #expect(deviceProfileJSON(activationBody) == testProfile)

        LicenseURLProtocol.response = #"{"success":true,"valid":false,"reason":"device_deactivated"}"#
        let validation = try await client.validate(licenseKey: "ABC", deviceID: "device-1")
        switch validation {
        case .failure(let reason):
            #expect(reason == .deviceDeactivated)
        case .success:
            Issue.record("Expected validation to fail")
        }
        #expect(LicenseURLProtocol.lastRequest?.url?.path == "/api/v1/license/validate")

        LicenseURLProtocol.response = #"{"success":true,"valid":true,"license_token":"payload2.signature2"}"#
        let revalidation = try await client.validate(licenseKey: "ABC", deviceID: "device-1")
        switch revalidation {
        case .success(let token):
            #expect(token == "payload2.signature2")
        case .failure:
            Issue.record("Expected validation to succeed")
        }

        LicenseURLProtocol.response = #"{"success":true}"#
        try await client.deactivate(licenseKey: "ABC", deviceID: "device-1")
        #expect(LicenseURLProtocol.lastRequest?.url?.path == "/api/v1/license/deactivate")
    }

    @Test func serverErrorIsDecoded() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LicenseURLProtocol.self]
        let client = LicenseAPIClient(
            baseURL: URL(string: "https://example.test/api/v1/license")!,
            session: URLSession(configuration: configuration)
        )
        LicenseURLProtocol.response =
            #"{"success":false,"error":{"code":"SEAT_LIMIT_REACHED","message":"No seats left","field":"license_key"}}"#

        do {
            _ = try await client.activate(licenseKey: "ABC", deviceID: "device", deviceName: nil, deviceProfile: nil)
            Issue.record("Expected activation to fail")
        } catch let error as LicenseAPIError {
            #expect(error.code == "SEAT_LIMIT_REACHED")
            #expect(error.message == "No seats left")
            #expect(error.field == "license_key")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // A nil deviceName/deviceProfile must be omitted from the JSON body
        // entirely, not sent as an explicit null.
        let body = LicenseURLProtocol.lastJSONBody ?? [:]
        #expect(body["device_name"] == nil)
        #expect(body["device_profile"] == nil)
    }

    @Test func trialStatusDecodesInvalidReason() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LicenseURLProtocol.self]
        let client = LicenseAPIClient(
            baseURL: URL(string: "https://example.test/api/v1/license")!,
            session: URLSession(configuration: configuration)
        )
        LicenseURLProtocol.response = #"{"success":true,"valid":false,"reason":"trial_expired"}"#

        let result = try await client.trialStatus(deviceID: "device", product: "forel")
        switch result {
        case .failure(let reason):
            #expect(reason == .trialExpired)
        case .success:
            Issue.record("Expected trial status to be invalid")
        }
    }
}

private func deviceProfileJSON(_ body: [String: Any]) -> DeviceProfile? {
    guard let profile = body["device_profile"] as? [String: Any],
          let model = profile["model"] as? String,
          let cpu = profile["cpu"] as? String,
          let macosVersion = profile["macos_version"] as? String,
          let cpuCount = profile["cpu_count"] as? Int,
          let memoryMB = profile["memory_mb"] as? Int,
          let appVersion = profile["app_version"] as? String,
          let preferredLanguage = profile["preferred_language"] as? String else {
        return nil
    }
    return DeviceProfile(
        model: model,
        cpu: cpu,
        macosVersion: macosVersion,
        cpuCount: cpuCount,
        memoryMB: memoryMB,
        appVersion: appVersion,
        preferredLanguage: preferredLanguage
    )
}

private final class LicenseURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response = #"{"success":true}"#
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastJSONBody: [String: Any]?

    static func reset() {
        response = #"{"success":true}"#
        lastRequest = nil
        lastJSONBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let body = request.httpBody ?? Self.read(request.httpBodyStream) {
            Self.lastJSONBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        let data = Data(Self.response.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
