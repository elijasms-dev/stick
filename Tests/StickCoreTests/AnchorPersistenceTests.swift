import XCTest
@testable import StickCore

final class AnchorPersistenceTests: XCTestCase {
    func testContextRefreshPreservesNewerBodyAndTimestamp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try NoteStore(directory: directory)
        let old = TextAnchor(quote: "target", prefix: "before ", suffix: " after", originalOffset: 7)
        let new = TextAnchor(quote: "target", prefix: "edited before ", suffix: " after", originalOffset: 14)
        var note = StickNote(body: "New writing", appBundleID: "test", appName: "Test", documentID: "test", documentTitle: "Test", anchor: old)
        note.updatedAt = Date(timeIntervalSince1970: 1234)
        try store.upsert(note)
        try store.updateAnchors([note.id: new], expected: [note.id: old])
        let saved = try XCTUnwrap(try NoteStore(directory: directory).notes.first)
        XCTAssertEqual(saved.anchor, new)
        XCTAssertEqual(saved.body, note.body)
        XCTAssertEqual(saved.updatedAt, note.updatedAt)
        // A delayed scan must not undo a more recent reattachment.
        try store.updateAnchors([note.id: old], expected: [note.id: old])
        XCTAssertEqual(store.notes.first?.anchor, new)
        try store.delete(id: note.id)
        try store.updateAnchors([note.id: new], expected: [note.id: old])
        XCTAssertTrue(store.notes.isEmpty)
    }
}
