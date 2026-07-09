import Foundation

/// Machine info sent once with `/activate` and `/trial/start`, matching the
/// `device_profile` shape from the license server's own example (`model`,
/// `cpu`, `macos_version`). Purely informational — the server stores it as a
/// free-form JSON blob and never uses it to gate access. No identifier beyond
/// the existing `device_id` (no separate random UUID).
public struct DeviceProfile: Encodable, Equatable, Sendable {
    public let model: String
    public let cpu: String
    public let macosVersion: String
    public let cpuCount: Int
    public let memoryMB: Int
    public let appVersion: String
    public let preferredLanguage: String

    public init(
        model: String,
        cpu: String,
        macosVersion: String,
        cpuCount: Int,
        memoryMB: Int,
        appVersion: String,
        preferredLanguage: String
    ) {
        self.model = model
        self.cpu = cpu
        self.macosVersion = macosVersion
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.appVersion = appVersion
        self.preferredLanguage = preferredLanguage
    }

    enum CodingKeys: String, CodingKey {
        case model
        case cpu
        case macosVersion = "macos_version"
        case cpuCount = "cpu_count"
        case memoryMB = "memory_mb"
        case appVersion = "app_version"
        case preferredLanguage = "preferred_language"
    }

    public static var current: DeviceProfile {
        DeviceProfile(
            model: hardwareModel() ?? "unknown",
            cpu: cpuArchitecture,
            macosVersion: macosVersionString,
            cpuCount: ProcessInfo.processInfo.processorCount,
            memoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            preferredLanguage: Locale.preferredLanguages.first ?? "en"
        )
    }

    private static var cpuArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static var macosVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func hardwareModel() -> String? {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
