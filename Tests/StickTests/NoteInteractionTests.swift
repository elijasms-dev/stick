import AppKit
import XCTest
import StickCore
@testable import Stick

@MainActor
private func descendants<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    let matches = (view as? T).map { [$0] } ?? []
    return matches + view.subviews.flatMap { descendants(type, in: $0) }
}

private func sampleNote(body: String = "Original") -> StickNote {
    StickNote(body: body, appBundleID: "com.apple.TextEdit", appName: "TextEdit", documentID: "file:///sample.txt", documentTitle: "sample.txt", anchor: TextAnchor(quote: "selected passage", prefix: "", suffix: "", originalOffset: 10))
}

final class NoteInteractionTests: XCTestCase {
    func testTypingCoalescesWritesAndCloseFlushesLatestText() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var saved: [StickNote] = []
            let editor = NoteEditorController(note: sampleNote(), onChange: { saved.append($0); return true }, onDelete: { _ in true }, onClose: {})
            let text = try XCTUnwrap(descendants(NSTextView.self, in: editor.window?.contentView).first)
            text.string = "First edit"
            editor.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
            text.string = "Latest edit"
            editor.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
            XCTAssertTrue(saved.isEmpty, "Typing should not synchronously rewrite the note store")
            editor.close()
            XCTAssertEqual(saved.map(\.body), ["Latest edit"])
            XCTAssertTrue(editor.flushChanges())
            XCTAssertEqual(saved.count, 1)
        }
    }

    func testFailedSaveKeepsDirtyTextForRetry() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var canSave = false
            var saved: [String] = []
            let editor = NoteEditorController(note: sampleNote(), onChange: { saved.append($0.body); return canSave }, onDelete: { _ in false }, onClose: {})
            let text = try XCTUnwrap(descendants(NSTextView.self, in: editor.window?.contentView).first)
            text.string = "Keep this draft"
            editor.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
            XCTAssertFalse(editor.flushChanges())
            canSave = true
            XCTAssertTrue(editor.flushChanges())
            XCTAssertEqual(saved, ["Keep this draft", "Keep this draft"])
            editor.close()
            XCTAssertEqual(saved.count, 2)
        }
    }

    func testDeletingDiscardsPendingSaveInsteadOfRecreatingDeletedNote() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var writes = 0
            let editor = NoteEditorController(note: sampleNote(), onChange: { _ in writes += 1; return true }, onDelete: { _ in true }, onClose: {})
            let text = try XCTUnwrap(descendants(NSTextView.self, in: editor.window?.contentView).first)
            text.string = "Discard with deleted note"
            editor.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
            editor.discardAndClose()
            XCTAssertTrue(editor.flushChanges())
            XCTAssertEqual(writes, 0)
        }
    }

    func testHiddenListDefersReloadAndSearchReturnOpensMatchingNote() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var opened: UUID?
            let list = NotesListController(onOpen: { opened = $0 }, onReveal: { _ in }, onReattach: { _ in }, onDelete: { _ in })
            defer { list.close() }
            let a = sampleNote(body: "Find the alpha detail")
            let b = sampleNote(body: "Review beta")
            list.update(notes: [a, b], unplaced: [])
            let table = try XCTUnwrap(descendants(NSTableView.self, in: list.window?.contentView).first)
            let search = try XCTUnwrap(descendants(NSSearchField.self, in: list.window?.contentView).first)
            XCTAssertEqual(table.numberOfRows, 0, "Invisible lists should not redraw on every edit")
            search.stringValue = "alpha"
            list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            XCTAssertEqual(table.numberOfRows, 1)
            XCTAssertTrue(list.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(opened, a.id)
        }
    }

    func testRemovingSelectedSearchResultClearsSelection() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var opened: UUID?
            let list = NotesListController(onOpen: { opened = $0 }, onReveal: { _ in }, onReattach: { _ in }, onDelete: { _ in })
            defer { list.close() }
            let a = sampleNote(body: "alpha"), b = sampleNote(body: "beta")
            list.update(notes: [a, b], unplaced: [])
            let table = try XCTUnwrap(descendants(NSTableView.self, in: list.window?.contentView).first)
            let search = try XCTUnwrap(descendants(NSSearchField.self, in: list.window?.contentView).first)
            search.stringValue = "alpha"
            list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            search.stringValue = "beta"
            list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            XCTAssertEqual(table.selectedRow, -1, "A row index must not silently select a different note")
            XCTAssertNil(opened)
        }
    }
}
