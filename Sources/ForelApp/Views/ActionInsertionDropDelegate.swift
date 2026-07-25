// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421

import SwiftUI
import UniformTypeIdentifiers

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
