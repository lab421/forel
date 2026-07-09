import Foundation
import IOKit

public struct HardwareDeviceIdentifierProvider: DeviceIdentifierProviding {
    private static let fallbackIdentifierKey = "device.fallbackIdentifier"

    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: "com.lab421.forel") ?? .standard) {
        self.defaults = defaults
    }

    public var deviceID: String {
        if let uuid = ioRegistryStringProperty(key: "IOPlatformUUID") {
            return uuid
        }
        if let serialNumber = ioRegistryStringProperty(key: "IOPlatformSerialNumber") {
            return serialNumber
        }
        if let persisted = defaults.string(forKey: Self.fallbackIdentifierKey) {
            return persisted
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Self.fallbackIdentifierKey)
        return generated
    }

    private func ioRegistryStringProperty(key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
