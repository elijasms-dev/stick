import AppKit
import Carbon
import XCTest
@testable import Stick

private final class FakeHotkeyRegistrar: HotkeyRegistering {
    var system = Set<KeyboardShortcut>()
    var failures: [KeyboardShortcut: OSStatus] = [:]
    var registered: [UInt32: KeyboardShortcut] = [:]
    var registrationCalls: [KeyboardShortcut] = []
    var unregistered: [UInt32] = []
    var installs = 0
    var deliver: ((UInt32) -> Void)?
    func installHandler(deliver: @escaping (UInt32) -> Void) -> OSStatus {
        installs += 1; self.deliver = deliver; return noErr
    }
    func enabledSystemShortcuts() throws -> Set<KeyboardShortcut> { system }
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> OSStatus {
        registrationCalls.append(shortcut)
        if let status = failures[shortcut] { return status }
        guard !registered.values.contains(shortcut) else { return OSStatus(eventHotKeyExistsErr) }
        registered[eventID] = shortcut
        return noErr
    }
    func unregister(eventID: UInt32) { registered.removeValue(forKey: eventID); unregistered.append(eventID) }
    func stop() { registered.removeAll(); deliver = nil }
}

final class HotkeysTests: XCTestCase {
    private func shortcut(_ key: Int) -> KeyboardShortcut {
        KeyboardShortcut(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey | cmdKey))
    }

    func testPartialFailureKeepsBothExistingBindingsAndCleansNewReservation() throws {
        let backend = FakeHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: backend)
        try hotkeys.start()
        let original = backend.registered
        let next = ShortcutConfiguration(addNote: shortcut(kVK_ANSI_J), togglePins: shortcut(kVK_ANSI_K))
        backend.failures[next.togglePins] = OSStatus(eventHotKeyExistsErr)
        XCTAssertThrowsError(try hotkeys.apply(configuration: next)) { error in
            guard case Hotkeys.Failure.registration(.togglePins, next.togglePins, OSStatus(eventHotKeyExistsErr)) = error else {
                return XCTFail("Wrong failure: \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains(next.togglePins.displayString))
            XCTAssertTrue(error.localizedDescription.contains("already in use"))
        }
        XCTAssertEqual(backend.registered, original)
        XCTAssertEqual(hotkeys.configuration, .defaults)
        XCTAssertEqual(backend.unregistered.count, 1)
        var actions: [UInt32] = []
        hotkeys.onPress = { actions.append($0) }
        for action in ShortcutAction.allCases {
            let id = try XCTUnwrap(original.first { $0.value == ShortcutConfiguration.defaults[action] }?.key)
            backend.deliver?(id)
        }
        XCTAssertEqual(actions, [1, 2])
    }

    func testSwappingActionsDoesNotReleaseOrReregisterKeys() throws {
        let backend = FakeHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: backend)
        try hotkeys.start()
        let oldAddID = try XCTUnwrap(backend.registered.first { $0.value == ShortcutConfiguration.defaults.addNote }?.key)
        let oldToggleID = try XCTUnwrap(backend.registered.first { $0.value == ShortcutConfiguration.defaults.togglePins }?.key)
        let swapped = ShortcutConfiguration(addNote: ShortcutConfiguration.defaults.togglePins,
                                            togglePins: ShortcutConfiguration.defaults.addNote)
        try hotkeys.apply(configuration: swapped)
        XCTAssertEqual(backend.registrationCalls.count, 2)
        XCTAssertTrue(backend.unregistered.isEmpty)
        var actions: [UInt32] = []
        hotkeys.onPress = { actions.append($0) }
        backend.deliver?(oldAddID)
        backend.deliver?(oldToggleID)
        XCTAssertEqual(actions, [2, 1])
        XCTAssertEqual(hotkeys.configuration, swapped)
    }

    func testChangingOneBindingKeepsOtherAndIgnoresStaleEvents() throws {
        let backend = FakeHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: backend)
        try hotkeys.start()
        let oldAddID = try XCTUnwrap(backend.registered.first { $0.value == ShortcutConfiguration.defaults.addNote }?.key)
        let toggleID = try XCTUnwrap(backend.registered.first { $0.value == ShortcutConfiguration.defaults.togglePins }?.key)
        let next = ShortcutConfiguration(addNote: shortcut(kVK_ANSI_J), togglePins: ShortcutConfiguration.defaults.togglePins)
        try hotkeys.apply(configuration: next)
        XCTAssertEqual(backend.registrationCalls.count, 3)
        XCTAssertEqual(backend.registered[toggleID], next.togglePins)
        XCTAssertNil(backend.registered[oldAddID])
        var actions: [UInt32] = []
        hotkeys.onPress = { actions.append($0) }
        backend.deliver?(oldAddID)
        backend.deliver?(toggleID)
        XCTAssertEqual(actions, [2])
    }

    func testFailedStartupCanRetryWithoutLeakingReservations() throws {
        let backend = FakeHotkeyRegistrar()
        backend.failures[ShortcutConfiguration.defaults.togglePins] = OSStatus(eventHotKeyExistsErr)
        let hotkeys = Hotkeys(registrar: backend)
        XCTAssertThrowsError(try hotkeys.start())
        XCTAssertTrue(backend.registered.isEmpty)
        XCTAssertNil(hotkeys.configuration)
        backend.failures.removeAll()
        try hotkeys.start()
        XCTAssertEqual(backend.registered.count, 2)
        XCTAssertEqual(backend.installs, 1)
        hotkeys.stop()
        XCTAssertTrue(backend.registered.isEmpty)
        XCTAssertNil(hotkeys.configuration)
    }

    func testSystemConflictIsRejectedBeforeChangingExistingBindings() throws {
        let backend = FakeHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: backend)
        try hotkeys.start()
        let original = backend.registered
        let next = ShortcutConfiguration(addNote: shortcut(kVK_ANSI_J), togglePins: ShortcutConfiguration.defaults.togglePins)
        backend.system.insert(next.addNote)
        XCTAssertThrowsError(try hotkeys.apply(configuration: next)) { error in
            guard case Hotkeys.Failure.systemReserved(.addNote, next.addNote) = error else {
                return XCTFail("Expected a system shortcut warning")
            }
        }
        XCTAssertEqual(backend.registered, original)
        XCTAssertEqual(backend.registrationCalls.count, 2)
        XCTAssertEqual(hotkeys.configuration, .defaults)
    }

    func testDuplicateActionsAndUnsafeKeysAreRejectedWithoutRegistration() {
        let backend = FakeHotkeyRegistrar()
        let hotkeys = Hotkeys(registrar: backend)
        let duplicate = ShortcutConfiguration(addNote: .init(keyCode: 0, modifiers: UInt32(controlKey)),
                                               togglePins: .init(keyCode: 0, modifiers: UInt32(controlKey)))
        XCTAssertThrowsError(try hotkeys.apply(configuration: duplicate))
        for modifiers in [UInt32(0), UInt32(shiftKey), UInt32(controlKey) | (1 << 30)] {
            let invalid = ShortcutConfiguration(addNote: .init(keyCode: 0, modifiers: modifiers),
                                                togglePins: ShortcutConfiguration.defaults.togglePins)
            XCTAssertThrowsError(try hotkeys.apply(configuration: invalid))
        }
        XCTAssertThrowsError(try KeyboardShortcut(keyCode: UInt32.max, modifiers: UInt32(cmdKey)).validate(for: .addNote))
        XCTAssertEqual(backend.installs, 0)
        XCTAssertTrue(backend.registrationCalls.isEmpty)
    }

    func testStandardStickCommandsAreReserved() {
        for code in [kVK_ANSI_Q,kVK_ANSI_W,kVK_ANSI_Z,kVK_ANSI_X,kVK_ANSI_C,kVK_ANSI_V,kVK_ANSI_A,kVK_ANSI_Comma] {
            XCTAssertThrowsError(try KeyboardShortcut(keyCode: UInt32(code), modifiers: UInt32(cmdKey)).validate(for: .addNote))
        }
        XCTAssertThrowsError(try KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey)).validate(for: .togglePins))
        XCTAssertNoThrow(try shortcut(kVK_ANSI_Q).validate(for: .addNote))
    }

    func testPreferencesPersistValidConfigurationAndRejectInvalidReplacement() throws {
        let name = "StickShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(preferences.load(), .defaults)
        let changed = ShortcutConfiguration(addNote: shortcut(kVK_ANSI_J), togglePins: shortcut(kVK_ANSI_K))
        try preferences.save(changed)
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).load(), changed)
        let data = defaults.data(forKey: ShortcutPreferences.storageKey)
        XCTAssertThrowsError(try preferences.save(ShortcutConfiguration(addNote: changed.addNote, togglePins: changed.addNote)))
        XCTAssertEqual(defaults.data(forKey: ShortcutPreferences.storageKey), data)
        defaults.set(Data("broken json".utf8), forKey: ShortcutPreferences.storageKey)
        XCTAssertEqual(preferences.load(), .defaults)
    }

    func testSystemHotkeyParsingIgnoresDisabledEntriesAndPreservesFnModifiers() {
        let code = UInt32(kVK_ANSI_J), modifiers = UInt32(controlKey | optionKey)
        let entries: [[String: Any]] = [
            [kHISymbolicHotKeyEnabled as String:true, kHISymbolicHotKeyCode as String:code, kHISymbolicHotKeyModifiers as String:modifiers],
            [kHISymbolicHotKeyEnabled as String:false, kHISymbolicHotKeyCode as String:UInt32(kVK_ANSI_K), kHISymbolicHotKeyModifiers as String:modifiers],
            [kHISymbolicHotKeyEnabled as String:true, kHISymbolicHotKeyCode as String:code, kHISymbolicHotKeyModifiers as String:modifiers | UInt32(kEventKeyModifierFnMask)],
            [kHISymbolicHotKeyEnabled as String:true]
        ]
        let parsed = CarbonHotkeyRegistrar.enabledShortcuts(in: entries)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertTrue(parsed.contains(KeyboardShortcut(keyCode: code, modifiers: modifiers)))
        XCTAssertTrue(parsed.contains(KeyboardShortcut(keyCode: code, modifiers: modifiers | UInt32(kEventKeyModifierFnMask))))
    }

    func testDisplayAndMenuModifiersUseTheSavedCombination() {
        let shortcut = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(shortcut.menuModifierMask, [.control,.option,.shift,.command])
        XCTAssertTrue(shortcut.displayString.hasPrefix("⌃⌥⇧⌘"))
        XCTAssertTrue(shortcut.spokenString.hasPrefix("Control Option Shift Command "))
        XCTAssertFalse(shortcut.menuKeyEquivalent.isEmpty)
    }
}
