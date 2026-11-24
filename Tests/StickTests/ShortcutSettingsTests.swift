import AppKit
import Carbon
import XCTest
@testable import Stick

@MainActor
private func shortcutControls<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    let matches = (view as? T).map { [$0] } ?? []
    return matches + view.subviews.flatMap { shortcutControls(type, in: $0) }
}

@MainActor
private func chooseKey(_ keyCode: UInt32, action: ShortcutAction, controller: ShortcutSettingsController) throws {
    let popup = try XCTUnwrap(shortcutControls(NSPopUpButton.self, in: controller.window?.contentView).first {
        $0.identifier?.rawValue == "shortcut-\(action.rawValue)-key"
    })
    XCTAssertTrue(popup.selectItem(withTag: Int(keyCode)))
    if let selector = popup.action { NSApp.sendAction(selector, to: popup.target, from: popup) }
}

final class ShortcutSettingsTests: XCTestCase {
    func testDraftDoesNotApplyUntilExplicitApply() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var applied: [ShortcutConfiguration] = []
            let controller = ShortcutSettingsController(configuration: .defaults) { applied.append($0); return nil }
            defer { controller.close() }
            try chooseKey(UInt32(kVK_ANSI_K), action: .addNote, controller: controller)
            XCTAssertTrue(applied.isEmpty)
            XCTAssertEqual(controller.savedConfiguration, .defaults)
            XCTAssertEqual(controller.draftConfiguration.addNote.keyCode, UInt32(kVK_ANSI_K))
            controller.applyChanges()
            XCTAssertEqual(applied, [controller.draftConfiguration])
            XCTAssertEqual(controller.savedConfiguration, controller.draftConfiguration)
        }
    }

    func testConflictKeepsDraftAndSavedShortcutsForRetry() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var conflict = true
            var attempts = 0
            let controller = ShortcutSettingsController(configuration: .defaults) { _ in
                attempts += 1
                return conflict ? "This shortcut is already in use. Choose another combination." : nil
            }
            defer { controller.close() }
            try chooseKey(UInt32(kVK_ANSI_K), action: .addNote, controller: controller)
            controller.applyChanges()
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(controller.savedConfiguration, .defaults)
            XCTAssertEqual(controller.draftConfiguration.addNote.keyCode, UInt32(kVK_ANSI_K))
            XCTAssertTrue(shortcutControls(NSTextField.self, in: controller.window?.contentView)
                .contains { $0.stringValue.contains("already in use") })
            conflict = false
            controller.applyChanges()
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(controller.savedConfiguration, controller.draftConfiguration)
        }
    }

    func testRestoreDefaultsRemainsADraftUntilApplied() async throws {
        await MainActor.run {
            _ = NSApplication.shared
            var custom = ShortcutConfiguration.defaults
            custom.addNote = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
            var applies = 0
            let controller = ShortcutSettingsController(configuration: custom) { _ in applies += 1; return nil }
            defer { controller.close() }
            controller.restoreDefaults()
            XCTAssertEqual(controller.draftConfiguration, .defaults)
            XCTAssertEqual(controller.savedConfiguration, custom)
            XCTAssertEqual(applies, 0)
            controller.applyChanges()
            XCTAssertEqual(controller.savedConfiguration, .defaults)
            XCTAssertEqual(applies, 1)
        }
    }

    func testDuplicateDraftNeverCallsRegistration() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var applies = 0
            let controller = ShortcutSettingsController(configuration: .defaults) { _ in applies += 1; return nil }
            defer { controller.close() }
            try chooseKey(ShortcutConfiguration.defaults.togglePins.keyCode, action: .addNote, controller: controller)
            controller.applyChanges()
            XCTAssertEqual(applies, 0)
            XCTAssertEqual(controller.savedConfiguration, .defaults)
            XCTAssertNotEqual(controller.draftConfiguration, controller.savedConfiguration)
            XCTAssertTrue(shortcutControls(NSButton.self, in: controller.window?.contentView)
                .contains { $0.title == "Apply" && $0.isEnabled })
        }
    }

    func testClosingDiscardsDraftWithoutApplying() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            var applies = 0
            let controller = ShortcutSettingsController(configuration: .defaults) { _ in applies += 1; return nil }
            defer { controller.close() }
            try chooseKey(UInt32(kVK_ANSI_K), action: .addNote, controller: controller)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
            XCTAssertEqual(controller.draftConfiguration, .defaults)
            XCTAssertEqual(applies, 0)
        }
    }

    func testStartupWarningAllowsRetryWithoutChangingChoices() async throws {
        await MainActor.run {
            _ = NSApplication.shared
            var applies = 0
            let controller = ShortcutSettingsController(configuration: .defaults) { _ in applies += 1; return nil }
            defer { controller.close() }
            controller.update(configuration: .defaults, warning: "One shortcut is unavailable.")
            XCTAssertTrue(shortcutControls(NSButton.self, in: controller.window?.contentView)
                .contains { $0.title == "Apply" && $0.isEnabled })
            controller.applyChanges()
            XCTAssertEqual(applies, 1)
            XCTAssertEqual(controller.savedConfiguration, .defaults)
        }
    }
}
