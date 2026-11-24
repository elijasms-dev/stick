import XCTest
@testable import StickCore

final class AnchorMatcherTests: XCTestCase {
    func testQuoteSurvivesInsertionAboveIt() throws {
        let old = "line one\nline two\ncheck this function\nline four"
        let range = (old as NSString).range(of: "check this function")
        let anchor = try XCTUnwrap(TextAnchor.capture(text: old, range: range))
        let new = "two\ninserted lines\n" + old
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: new), .found((new as NSString).range(of: anchor.quote)))
    }

    func testUTF16OffsetsWithEmoji() throws {
        let text = "🧷 café\nFix 👩🏽‍💻 here\nfinish"
        let range = (text as NSString).range(of: "Fix 👩🏽‍💻 here")
        let anchor = try XCTUnwrap(TextAnchor.capture(text: text, range: range))
        XCTAssertEqual(anchor.quote, "Fix 👩🏽‍💻 here")
        XCTAssertEqual(anchor.originalOffset, range.location)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: text), .found(range))
    }

    func testDuplicateQuotesRequireContext() {
        let text = "first: target. second: target!"
        let anchor = TextAnchor(quote: "target", prefix: "second: ", suffix: "!", originalOffset: 0)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: text), .found(NSRange(location: 23, length: 6)))
        let ambiguous = TextAnchor(quote: "target", prefix: "", suffix: "", originalOffset: 7)
        XCTAssertEqual(AnchorMatcher.locate(ambiguous, in: text), .ambiguous)
    }

    func testIdenticalContextNeverUsesOldOffsetToGuess() {
        let anchor = TextAnchor(quote: "target", prefix: "a ", suffix: " b", originalOffset: 2)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: "a target b; a target b"), .ambiguous)
    }

    func testDeletingPinnedDuplicateDoesNotAttachToRemainingCopy() throws {
        let original = "first task: TODO, review this\nsecond task: TODO, keep this"
        let range = (original as NSString).range(of: "TODO")
        let anchor = try XCTUnwrap(TextAnchor.capture(text: original, range: range))
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: original), .found(range))
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: "second task: TODO, keep this"), .missing)
    }

    func testUniqueQuoteWithoutContextCanStillMatch() {
        let anchor = TextAnchor(quote: "target", prefix: "", suffix: "", originalOffset: 0)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: "find target here"), .found(NSRange(location: 5, length: 6)))
    }

    func testDeletedOrChangedQuoteIsMissing() {
        let anchor = TextAnchor(quote: "old code", prefix: "", suffix: "", originalOffset: 0)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: "new code"), .missing)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: ""), .missing)
    }

    func testOverlappingMatchesAreAmbiguous() {
        XCTAssertEqual(AnchorMatcher.locate(TextAnchor(quote: "ana", prefix: "", suffix: "", originalOffset: 1), in: "banana"), .ambiguous)
    }

    func testInvalidSelectionsAreRejected() {
        XCTAssertNil(TextAnchor.capture(text: "abc", range: NSRange(location: 4, length: 1)))
        XCTAssertNil(TextAnchor.capture(text: "abc", range: NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(TextAnchor.capture(text: "abc", range: NSRange(location: 0, length: 0)))
        XCTAssertNil(TextAnchor.capture(text: " ", range: NSRange(location: 0, length: 1)))
        XCTAssertNil(TextAnchor.capture(text: "🧷", range: NSRange(location: 1, length: 1)))
    }
}

final class NoteStoreTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("stick-tests-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func note() -> StickNote {
        StickNote(body: "Remember this", appBundleID: "com.apple.TextEdit", appName: "TextEdit", documentID: "file:///sample.txt", documentTitle: "sample.txt", anchor: TextAnchor(quote: "target", prefix: "", suffix: "", originalOffset: 40))
    }

    func testPersistsUpdatesAndDeletesAcrossReopen() throws {
        let store = try NoteStore(directory: directory)
        var saved = note()
        try store.upsert(saved)
        XCTAssertEqual(try NoteStore(directory: directory).notes, [saved])
        saved.body = "Updated with 🧷"
        saved.updatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        try store.upsert(saved)
        XCTAssertEqual(store.notes.count, 1)
        let reopened = try NoteStore(directory: directory)
        XCTAssertEqual(reopened.notes, [saved])
        try reopened.delete(id: saved.id)
        XCTAssertEqual(try NoteStore(directory: directory).notes, [])
    }

    func testCorruptFileIsPreserved() throws {
        let store = try NoteStore(directory: directory)
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try NoteStore(directory: directory))
        XCTAssertThrowsError(try store.upsert(note()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
        XCTAssertEqual(store.notes, [])
    }

    func testFutureVersionIsPreserved() throws {
        let store = try NoteStore(directory: directory)
        let future = Data("{\"version\":99,\"notes\":[]}".utf8)
        try future.write(to: store.fileURL)
        XCTAssertThrowsError(try NoteStore(directory: directory)) { error in
            guard case NoteStoreError.unsupportedVersion(99) = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertThrowsError(try store.delete(id: UUID()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), future)
    }

    func testFailedWriteDoesNotPublishUnsavedNote() throws {
        let store = try NoteStore(directory: directory)
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try store.upsert(note()))
        XCTAssertEqual(store.notes, [])
    }
}
