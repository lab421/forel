// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Payload type of an action being reordered. Deliberately not plain text:
    /// text fields accept dropped text, so a plain-text payload could write an
    /// action id into a script or rename-pattern field.
    static let forelActionID = UTType(exportedAs: "com.lab421.forel.action-id")
}

/// Handles a local action reorder without consuming drops from other apps.
struct ActionInsertionDropDelegate: DropDelegate {
    let insertionIndex: Int
    @Binding var draggedActionId: String?
    @Binding var activeInsertionIndex: Int?
    let move: (String, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedActionId != nil else { return }
        activeInsertionIndex = insertionIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedActionId != nil else { return nil }
        activeInsertionIndex = insertionIndex
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedActionId = nil
            activeInsertionIndex = nil
        }
        guard let actionId = draggedActionId else { return false }
        move(actionId, insertionIndex)
        return true
    }

    func dropExited(info: DropInfo) {
        if activeInsertionIndex == insertionIndex { activeInsertionIndex = nil }
    }
}
