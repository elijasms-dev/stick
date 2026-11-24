import AppKit
import XCTest
@testable import Stick

final class PinLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testOverlappingPinsKeepTheirTextLineAndSeparateHorizontally() throws {
        let first = UUID(), second = UUID(), third = UUID()
        let source = CGRect(x: 100, y: 300, width: 8, height: 16)
        let nearby = source.offsetBy(dx: 0, dy: 18)
        let frames = PinLayout.frames(pins: [(first, source), (second, source), (third, nearby)], screens: [screen])
        let a = try XCTUnwrap(frames[first]), b = try XCTUnwrap(frames[second]), c = try XCTUnwrap(frames[third])
        XCTAssertEqual(a.midY, source.midY)
        XCTAssertEqual(b.midY, source.midY)
        XCTAssertEqual(c.midY, nearby.midY)
        XCTAssertFalse(a.intersects(b))
        XCTAssertFalse(a.intersects(c))
        XCTAssertFalse(b.intersects(c))
    }

    func testNoteStoreOrderingDoesNotReshufflePins() {
        let a = UUID(), b = UUID(), c = UUID()
        let source = CGRect(x: 150, y: 300, width: 8, height: 16)
        let first = PinLayout.frames(pins: [(a, source), (b, source), (c, source)], screens: [screen])
        let reordered = PinLayout.frames(pins: [(c, source), (a, source), (b, source)], screens: [screen])
        XCTAssertEqual(first, reordered)
    }

    func testScrollingMovesPinBySameAmountAsItsLine() throws {
        let id = UUID()
        let source = CGRect(x: 150, y: 300, width: 8, height: 16)
        let before = try XCTUnwrap(PinLayout.frames(pins: [(id, source)], screens: [screen])[id])
        let after = try XCTUnwrap(PinLayout.frames(pins: [(id, source.offsetBy(dx: 0, dy: 47))], screens: [screen])[id])
        XCTAssertEqual(after.minY - before.minY, 47)
        XCTAssertEqual(after.minX, before.minX)
    }

    func testScreenEdgeDoesNotClampPinToAnotherLine() {
        let id = UUID()
        XCTAssertNil(PinLayout.frames(pins: [(id, CGRect(x: 100, y: 790, width: 8, height: 16))], screens: [screen])[id])
        XCTAssertNil(PinLayout.frames(pins: [(id, CGRect(x: 100, y: -30, width: 8, height: 16))], screens: [screen])[id])
    }

    func testCrowdedRowNeverWrapsToDifferentLine() {
        let smallScreen = CGRect(x: 0, y: 0, width: 100, height: 200)
        let source = CGRect(x: 50, y: 90, width: 8, height: 16)
        let pins = (0..<20).map { _ in (id: UUID(), rect: source) }
        let frames = PinLayout.frames(pins: pins, screens: [smallScreen])
        XCTAssertFalse(frames.isEmpty)
        XCTAssertLessThan(frames.count, pins.count)
        for frame in frames.values {
            XCTAssertEqual(frame.midY, source.midY)
            XCTAssertTrue(smallScreen.contains(frame))
        }
    }

    func testSecondScreenCoordinatesRemainOnTheirLine() throws {
        let second = CGRect(x: -1440, y: 180, width: 1440, height: 900)
        let id = UUID(), source = CGRect(x: -1200, y: 500, width: 8, height: 16)
        let frame = try XCTUnwrap(PinLayout.frames(pins: [(id, source)], screens: [screen, second])[id])
        XCTAssertEqual(frame.midY, source.midY)
        XCTAssertTrue(second.contains(frame))
    }
}
