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

/// A file whose rules couldn't move or copy it because a destination disk or
/// network share wasn't connected.
public struct VolumeUnavailableEvent: Equatable, Sendable {
    /// Names of the disks or shares, as under /Volumes.
    public let volumes: [String]
    public let ruleNames: [String]
    /// Whether the rules run again on the file once its disk or share is
    /// connected. Not when another action already changed it this time.
    public let willRetry: Bool
}

/// Automatic runs whose destination disk or network share isn't connected:
/// reported once per file, then run again when that disk or share comes back.
extension WatcherCoordinator {
    /// Runs the rules again on the files that couldn't be moved or copied
    /// because the disk or share mounted at `mountPoint` wasn't connected.
    public func volumeDidMount(atPath mountPoint: String) {
        let volume = (mountPoint as NSString).lastPathComponent
        processingQueue.async { [weak self] in
            self?.retryWaiting(forVolume: volume)
        }
    }

    /// Forgets the waiting files `isWatched` rejects.
    func keepWaiting(where isWatched: (String) -> Bool) {
        waitingForVolume = waitingForVolume.compactMapValues { paths in
            let kept = paths.filter(isWatched)
            return kept.isEmpty ? nil : kept
        }
    }

    private func retryWaiting(forVolume volume: String) {
        guard let paths = waitingForVolume.removeValue(forKey: volume) else { return }
        for path in paths.sorted() {
            // A file waiting on several volumes is retried once; it waits
            // again for whichever is still missing.
            waitingForVolume = waitingForVolume.compactMapValues { waiting in
                let kept = waiting.subtracting([path])
                return kept.isEmpty ? nil : kept
            }
            handle(path: path, retrying: true)
        }
    }

    /// Reports a failed move or copy whose destination disk or share isn't
    /// connected, and keeps the file to run its rules again when it is.
    func waitForDisconnectedVolumes(_ history: [HistoryEntry], path: String, rules: [Rule]) {
        let volumes = Self.disconnectedVolumes(in: history, rules: rules)
        guard !volumes.isEmpty else { return }
        // Running the rules again redoes every action on the file: only safe
        // when none was applied this time (a copy made before the failed move
        // would be made twice).
        let willRetry = !history.contains { $0.status == .applied }
        if willRetry {
            for volume in volumes {
                waitingForVolume[volume, default: []].insert(path)
            }
        }
        let failed = history.filter { $0.status == .failed }
        onVolumeUnavailable?(VolumeUnavailableEvent(
            volumes: volumes,
            ruleNames: Array(Set(failed.map(\.ruleName))).sorted(),
            willRetry: willRetry
        ))
    }

    /// The disks or shares, by name, that the failed moves and copies in
    /// `history` were headed to and that aren't connected.
    static func disconnectedVolumes(in history: [HistoryEntry], rules: [Rule]) -> [String] {
        var volumes = Set<String>()
        for entry in history where entry.status == .failed && [.moveToFolder, .copyToFolder].contains(entry.actionKind) {
            guard let rule = rules.first(where: { $0.id == entry.ruleId }) else { continue }
            for action in rule.actions where action.kind == entry.actionKind {
                guard let destination = action.params[ActionParam.destination]?.stringValue,
                      let volume = VolumePaths.unmountedVolume(of: destination)
                else { continue }
                volumes.insert(volume)
            }
        }
        return volumes.sorted()
    }
}
