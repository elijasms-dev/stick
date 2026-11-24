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

    func testUnrelatedRepeatedQuotesDoNotCreateContextualAmbiguity() {
        let anchor = TextAnchor(quote: "target", prefix: "specific ", suffix: " context", originalOffset: 9)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: "specific target context"), .found(NSRange(location: 9, length: 6)))
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: "other target elsewhere target"), .missing)
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

    func testLegacyAnchorDecodesWithoutReattachmentFlag() throws {
        let data = Data(#"{"quote":"target","prefix":"","suffix":"","originalOffset":0}"#.utf8)
        let anchor = try JSONDecoder().decode(TextAnchor.self, from: data)
        XCTAssertNil(anchor.requiresReattachment)
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: "target"), .found(NSRange(location: 0, length: 6)))
    }

    func testTrackingIdentityIgnoresOnlyReattachmentFlag() {
        let anchor = TextAnchor(quote: "target", prefix: "before", suffix: "after", originalOffset: 6)
        var changed = anchor
        changed.requiresReattachment = true
        XCTAssertTrue(anchor.hasSameAttachment(as: changed))
        changed.originalOffset += 1
        XCTAssertFalse(anchor.hasSameAttachment(as: changed))
        changed = anchor
        changed.prefix = "different"
        XCTAssertFalse(anchor.hasSameAttachment(as: changed))
    }
}

final class TextEditTrackerTests: XCTestCase {
    func testAdjacentEditsKeepTwoIndependentPins() throws {
        let previous = "heading\nfirst pinned line\nbetween\nsecond pinned line\nend"
        let current = "new heading\nextra line\nfirst pinned line\nbetween\nsecond pinned line\nend"
        let edit = TextEditTracker(from: previous, to: current)
        for quote in ["first pinned line", "second pinned line"] {
            let range = (previous as NSString).range(of: quote)
            let relocated = try XCTUnwrap(edit.relocate(quote: quote, range: range))
            XCTAssertEqual(relocated, (current as NSString).range(of: quote))
            // Refreshed context can be saved and located after restarting Stick.
            let refreshed = try XCTUnwrap(TextAnchor.capture(text: current, range: relocated))
            XCTAssertEqual(AnchorMatcher.locate(refreshed, in: current), .found(relocated))
        }
    }

    func testEditOnFollowingLineKeepsThePin() {
        let previous = "before\npinned text\nafter"
        let current = "before\npinned text\na rewritten following line"
        let range = (previous as NSString).range(of: "pinned text")
        XCTAssertEqual(TextEditTracker.relocate(quote: "pinned text", range: range, from: previous, to: current), range)
    }

    func testInsertionAndDeletionImmediatelyBeforeQuoteUseUTF16Offsets() throws {
        let previous = "🧷 introduction\npin 👩🏽‍💻 here\nend"
        let quote = "pin 👩🏽‍💻 here"
        let range = (previous as NSString).range(of: quote)
        let current = previous.replacingOccurrences(of: quote, with: "one more 🐈 line\n" + quote)
        let shifted = try XCTUnwrap(TextEditTracker.relocate(quote: quote, range: range, from: previous, to: current))
        XCTAssertEqual(shifted, (current as NSString).range(of: quote))
        XCTAssertEqual(TextEditTracker.relocate(quote: quote, range: shifted, from: current, to: previous), range)
    }

    func testDeletingEitherIdenticalQuoteDoesNotTransferPin() {
        let previous = "target\ntarget"
        for range in [NSRange(location: 0, length: 6), NSRange(location: 7, length: 6)] {
            XCTAssertNil(TextEditTracker.relocate(quote: "target", range: range, from: previous, to: "target"))
        }
    }

    func testInsertingIdenticalQuoteDoesNotGuessWhichCopyMoved() {
        XCTAssertNil(TextEditTracker.relocate(quote: "target", range: NSRange(location: 0, length: 6),
                                             from: "target", to: "target\ntarget"))
    }

    func testExistingRepeatedQuotesCanMoveTogether() {
        let previous = "first task: TODO, review this\nsecond task: TODO, keep this"
        let current = "inserted line\n" + previous
        for range in [NSRange(location: 12, length: 4), NSRange(location: 43, length: 4)] {
            XCTAssertEqual(TextEditTracker.relocate(quote: "TODO", range: range, from: previous, to: current),
                           NSRange(location: range.location + 14, length: range.length))
        }
    }

    func testDeletingPinnedDuplicateWithDifferentContextDoesNotAttachToSurvivor() {
        let previous = "first task: TODO, review this\nsecond task: TODO, keep this"
        let current = "second task: TODO, keep this"
        let range = (previous as NSString).range(of: "TODO")
        XCTAssertNil(TextEditTracker.relocate(quote: "TODO", range: range, from: previous, to: current))
    }

    func testEditsInsideOrAcrossTheQuoteRequireReattachment() {
        let previous = "before\npinned text\nafter"
        let range = (previous as NSString).range(of: "pinned text")
        for current in ["before\npinned NEW text\nafter", "BEFORE\npinned text\nAFTER", "before\nafter"] {
            XCTAssertNil(TextEditTracker.relocate(quote: "pinned text", range: range, from: previous, to: current))
        }
    }

    func testUnverifiedPriorRangeIsNeverTracked() {
        XCTAssertNil(TextEditTracker.relocate(quote: "target", range: NSRange(location: 0, length: 6),
                                             from: "wrong target", to: "new wrong target"))
    }

    func testObservedDeletionCannotFallBackToIdenticalSurvivorOnLaterScans() throws {
        let duplicate = String(repeating: "a", count: 80) + "target" + String(repeating: "b", count: 80)
        let distinct = String(repeating: "a", count: 60) + "X" + String(repeating: "a", count: 19)
            + "target" + String(repeating: "b", count: 80)
        let original = distinct + "\n" + duplicate
        let range = (original as NSString).range(of: "target")
        let anchor = try XCTUnwrap(TextAnchor.capture(text: original, range: range))
        XCTAssertEqual(AnchorMatcher.locate(anchor, in: original), .found(range))
        var tracker = try XCTUnwrap(LiveAnchorTracker(anchor: anchor, text: original, range: range))

        // A nearby edit makes the two passages identical, but live continuity
        // still knows which of them holds this note.
        let identical = duplicate + "\n" + duplicate
        XCTAssertEqual(tracker.apply(TextEditTracker(from: original, to: identical)), range)
        XCTAssertEqual(AnchorMatcher.locate(tracker.anchor, in: identical), .ambiguous)

        // A fresh static search would now choose the survivor incorrectly.
        XCTAssertNil(tracker.apply(TextEditTracker(from: identical, to: duplicate)))
        XCTAssertTrue(tracker.isInvalidated)

        // Persist the engine's rejection, then simulate a new process with no
        // live history. The otherwise matching survivor must remain unplaced.
        var invalidated = tracker.anchor
        invalidated.requiresReattachment = true
        let reopened = try JSONDecoder().decode(TextAnchor.self, from: JSONEncoder().encode(invalidated))
        XCTAssertEqual(reopened.requiresReattachment, true)
        XCTAssertEqual(AnchorMatcher.locate(reopened, in: duplicate), .missing)
        XCTAssertTrue(tracker.anchor.hasSameAttachment(as: reopened))
        XCTAssertEqual(AnchorMatcher.locate(tracker.anchor, in: duplicate), .found(range))
        XCTAssertNil(tracker.apply(TextEditTracker(from: identical, to: duplicate)))
        XCTAssertTrue(tracker.isInvalidated)

        // Exact undo restores the verified snapshot; choosing a new attachment
        // explicitly instead creates a fresh tracker.
        XCTAssertEqual(tracker.apply(TextEditTracker(from: identical, to: identical)), range)
        XCTAssertFalse(tracker.isInvalidated)
        XCTAssertNil(tracker.anchor.requiresReattachment)
        XCTAssertNotEqual(tracker.anchor, reopened) // Engine persists this flag-clearing update.
        let reattached = try XCTUnwrap(LiveAnchorTracker(anchor: tracker.anchor, text: duplicate, range: range))
        XCTAssertFalse(reattached.isInvalidated)
    }

    func testEditingPinnedQuoteStaysInvalidUntilExactUndo() throws {
        let original = "before\npinned text\nafter"
        let range = (original as NSString).range(of: "pinned text")
        let anchor = try XCTUnwrap(TextAnchor.capture(text: original, range: range))
        var tracker = try XCTUnwrap(LiveAnchorTracker(anchor: anchor, text: original, range: range))
        XCTAssertNil(tracker.apply(TextEditTracker(from: original, to: "before\nchanged text\nafter")))
        XCTAssertNil(tracker.apply(TextEditTracker(from: original, to: "before\nchanged text\nafter\npinned text")))
        XCTAssertEqual(tracker.apply(TextEditTracker(from: original, to: original)), range)
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
