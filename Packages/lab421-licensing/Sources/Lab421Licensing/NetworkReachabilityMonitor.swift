import Foundation
import Network

/// Notifies once when network connectivity transitions from unreachable to
/// reachable. Lets `LicenseManager` retry a trial/license sync that failed
/// at launch as soon as the network comes back, instead of waiting for its
/// next scheduled attempt.
@MainActor
public protocol NetworkReachabilityMonitoring {
    func startMonitoring(onReachable: @escaping @Sendable () -> Void)
}

@MainActor
public final class NWPathReachabilityMonitor: NetworkReachabilityMonitoring {
    private let monitor = NWPathMonitor()
    /// `nil` until the first path update arrives, so that update never
    /// itself counts as a reachability transition — only later flips from
    /// unreachable to reachable do.
    private var wasReachable: Bool?

    public init() {}

    public func startMonitoring(onReachable: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let becameReachable = isReachable && self.wasReachable == false
                self.wasReachable = isReachable
                if becameReachable {
                    onReachable()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.lab421.licensing.pathMonitor"))
    }
}
