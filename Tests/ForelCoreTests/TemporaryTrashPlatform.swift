import Foundation
@testable import ForelCore

struct TemporaryTrashPlatform: ActionPlatform {
    func open(path: String, application: String?, passFile: Bool, bringToFront: Bool) throws {}
    func showInFinder(path: String, bringToFront: Bool) throws {}
    func notify(text: String, sound: Bool) throws {}
    func pause(seconds: TimeInterval) throws {}
    func trash(path: String) throws -> String {
        let target = path + ".test-trash-" + UUID().uuidString
        try FileManager.default.moveItem(atPath: path, toPath: target)
        return target
    }
}
