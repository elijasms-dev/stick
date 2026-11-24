import AppKit
import Carbon
import XCTest
@testable import Stick

@MainActor
private func labels(in view: NSView?) -> [NSTextField] {
    guard let view else { return [] }
    let matches = (view as? NSTextField).map { [$0] } ?? []
    return matches + view.subviews.flatMap { labels(in: $0) }
}

final class ShortcutHintTests: XCTestCase {
    func testOnboardingHintsFollowAppliedConfigurationWithoutChangingPermissionStage() async {
        await MainActor.run {
            _ = NSApplication.shared
            let configuration = ShortcutConfiguration(
                addNote: KeyboardShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | shiftKey)),
                togglePins: KeyboardShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey | shiftKey)))
            let controller = OnboardingController(checkAccess: { true }, onFinish: {}, onShowNotes: {})
            defer { controller.close() }
            controller.updateShortcuts(configuration)
            let values = labels(in: controller.window?.contentView).map(\.stringValue)
            XCTAssertTrue(values.contains(configuration.addNote.displayString))
            XCTAssertTrue(values.contains(configuration.togglePins.displayString))
            XCTAssertFalse(values.contains(ShortcutConfiguration.defaults.addNote.displayString))
            XCTAssertEqual(controller.stage, .ready)
        }
    }

    func testEmptyNotesHintUsesTheChosenShortcut() async {
        await MainActor.run {
            _ = NSApplication.shared
            let shortcut = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | shiftKey))
            let list = NotesListController(onOpen: { _ in }, onReveal: { _ in }, onReattach: { _ in }, onDelete: { _ in })
            defer { list.close() }
            list.updateShortcut(shortcut)
            list.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertTrue(labels(in: list.window?.contentView).contains { $0.stringValue.contains("press \(shortcut.spokenString)") })
        }
    }
}
