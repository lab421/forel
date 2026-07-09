import Foundation

public actor LicenseAPIClient: LicenseAPIClientProtocol {
    private struct DeviceRegistrationRequest: Encodable {
        enum Identifier {
            case product(String)
            case license(String)
        }

        let deviceId: String
        let identifier: Identifier
        let deviceName: String?
        let deviceProfile: DeviceProfile?

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case productId = "product_id"
            case licenseKey = "license_key"
            case deviceName = "device_name"
            case deviceProfile = "device_profile"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(deviceId, forKey: .deviceId)
            switch identifier {
            case .product(let productId):
                try container.encode(productId, forKey: .productId)
            case .license(let licenseKey):
                try container.encode(licenseKey, forKey: .licenseKey)
            }
            try container.encodeIfPresent(deviceName, forKey: .deviceName)
            try container.encodeIfPresent(deviceProfile, forKey: .deviceProfile)
        }
    }

    private struct Response: Decodable {
        struct APIError: Decodable {
            let code: String
            let message: String
            let field: String?
        }

        let success: Bool
        let alreadyStarted: Bool?
        let valid: Bool?
        let reason: String?
        let licenseToken: String?
        let trialToken: String?
        let expiresAt: Date?
        let daysRemaining: Int?
        let error: APIError?
    }

    private let baseURL: URL
    private let trialBaseURL: URL
    private let session: URLSession
    
    public init(
        baseURL: URL = URL(string: "http://localhost:8787/api/v1/license")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.trialBaseURL = baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("trial")
        self.session = session
    }

    public func startTrial(deviceID: String, product: String, deviceName: String?, deviceProfile: DeviceProfile?) async throws {
        let response = try await post(
            to: trialBaseURL.appendingPathComponent("start"),
            body: DeviceRegistrationRequest(
                deviceId: deviceID,
                identifier: .product(product),
                deviceName: (deviceName?.isEmpty == false) ? deviceName : nil,
                deviceProfile: deviceProfile
            )
        )
        try requireSuccess(response)
    }

    public func trialStatus(deviceID: String, product: String) async throws -> Result<TrialStatus, TrialInvalidReason> {
        let response = try await post(
            to: trialBaseURL.appendingPathComponent("status"),
            body: ["device_id": deviceID, "product_id": product]
        )
        try requireSuccess(response)
        if response.valid == true,
           let daysRemaining = response.daysRemaining,
           let expiresAt = response.expiresAt {
            return .success(TrialStatus(daysRemaining: daysRemaining, expiresAt: expiresAt, trialToken: response.trialToken))
        }
        return .failure(TrialInvalidReason(serverValue: response.reason))
    }

    public func activate(
        licenseKey: String,
        deviceID: String,
        deviceName: String?,
        deviceProfile: DeviceProfile?
    ) async throws -> String? {
        let response = try await post(
            to: baseURL.appendingPathComponent("activate"),
            body: DeviceRegistrationRequest(
                deviceId: deviceID,
                identifier: .license(licenseKey),
                deviceName: (deviceName?.isEmpty == false) ? deviceName : nil,
                deviceProfile: deviceProfile
            )
        )
        try requireSuccess(response)
        return response.licenseToken
    }

    public func validate(licenseKey: String, deviceID: String) async throws -> Result<String?, LicenseInvalidReason> {
        let response = try await post(
            to: baseURL.appendingPathComponent("validate"),
            body: ["license_key": licenseKey, "device_id": deviceID]
        )
        try requireSuccess(response)
        return response.valid == true
            ? .success(response.licenseToken)
            : .failure(LicenseInvalidReason(serverValue: response.reason))
    }

    public func deactivate(licenseKey: String, deviceID: String) async throws {
        let response = try await post(
            to: baseURL.appendingPathComponent("deactivate"),
            body: ["license_key": licenseKey, "device_id": deviceID]
        )
        try requireSuccess(response)
    }

    private func post<Body: Encodable>(to url: URL, body: Body) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private func requireSuccess(_ response: Response) throws {
        guard response.success else {
            if let error = response.error {
                throw LicenseAPIError(code: error.code, message: error.message, field: error.field)
            }
            throw LicenseAPIError(
                code: "INVALID_RESPONSE",
                message: "The license server returned an invalid response.",
                field: nil
            )
        }
    }
}
