import AppKit
import Carbon

/// Carbon operations run on the application's main thread. Injection keeps
/// configuration and rollback tests independent of the user's global shortcuts.
protocol HotkeyRegistering: AnyObject {
    func installHandler(deliver: @escaping (UInt32) -> Void) -> OSStatus
    func enabledSystemShortcuts() throws -> Set<KeyboardShortcut>
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> OSStatus
    func unregister(eventID: UInt32)
    func stop()
}

final class Hotkeys {
    private let registrar: HotkeyRegistering
    private var registered: [KeyboardShortcut: UInt32] = [:]
    private var actionsByEventID: [UInt32: ShortcutAction] = [:]
    private var nextEventID: UInt32 = 1
    private var handlerInstalled = false
    private(set) var configuration: ShortcutConfiguration?
    var onPress: ((UInt32) -> Void)?

    init(registrar: HotkeyRegistering = CarbonHotkeyRegistrar()) { self.registrar = registrar }
    func start(configuration: ShortcutConfiguration = .defaults) throws { try apply(configuration: configuration) }

    func apply(configuration next: ShortcutConfiguration) throws {
        try next.validate()
        let systemShortcuts = try registrar.enabledSystemShortcuts()
        for action in ShortcutAction.allCases where systemShortcuts.contains(next[action]) {
            throw Failure.systemReserved(action, next[action])
        }
        if !handlerInstalled {
            let status = registrar.installHandler { [weak self] eventID in
                guard let self, let action = self.actionsByEventID[eventID] else { return }
                self.onPress?(action.rawValue)
            }
            guard status == noErr else { throw Failure.handler(status) }
            handlerInstalled = true
        }
        // Acquire every new key before releasing old ones. IDs belong to key
        // combinations; swapping the two actions only changes dispatch mapping.
        var added: [KeyboardShortcut: UInt32] = [:]
        do {
            for action in ShortcutAction.allCases {
                let shortcut = next[action]
                guard registered[shortcut] == nil else { continue }
                let id = nextEventID
                nextEventID &+= 1
                if nextEventID == 0 { nextEventID = 1 }
                let status = registrar.register(shortcut, eventID: id)
                guard status == noErr else { throw Failure.registration(action, shortcut, status) }
                added[shortcut] = id
            }
        } catch {
            added.values.forEach { registrar.unregister(eventID: $0) }
            throw error
        }
        let wanted = Set(ShortcutAction.allCases.map { next[$0] })
        for (shortcut, id) in registered where !wanted.contains(shortcut) { registrar.unregister(eventID: id) }
        registered = registered.filter { wanted.contains($0.key) }
        registered.merge(added) { existing, _ in existing }
        actionsByEventID = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
            registered[next[action]].map { ($0, action) }
        })
        configuration = next
    }

    func stop() {
        registrar.stop()
        registered.removeAll()
        actionsByEventID.removeAll()
        handlerInstalled = false
        configuration = nil
    }

    enum Failure: LocalizedError {
        case handler(OSStatus)
        case systemCheck(OSStatus)
        case systemReserved(ShortcutAction, KeyboardShortcut)
        case registration(ShortcutAction, KeyboardShortcut, OSStatus)
        var errorDescription: String? {
            switch self {
            case .handler(let status):
                return "Stick couldn’t start its shortcut listener (error \(status)). Menu commands are still available."
            case .systemCheck(let status):
                return "Stick couldn’t check macOS shortcuts (error \(status)). Try applying your shortcuts again."
            case .systemReserved(let action, let shortcut):
                return "\(shortcut.displayString) for \(action.title.lowercased()) is already assigned to a macOS shortcut. Choose another combination."
            case .registration(let action, let shortcut, let status):
                if status == OSStatus(eventHotKeyExistsErr) {
                    return "macOS reports that \(shortcut.displayString) for \(action.title.lowercased()) is already in use. Choose another combination."
                }
                return "macOS couldn’t register \(shortcut.displayString) for \(action.title.lowercased()) (error \(status)). Choose another combination."
            }
        }
    }
}

/// Main-thread-only adapter. macOS cannot report every app-specific shortcut.
final class CarbonHotkeyRegistrar: HotkeyRegistering {
    private static let signature: OSType = 0x5354494B
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var deliver: ((UInt32) -> Void)?

    func installHandler(deliver: @escaping (UInt32) -> Void) -> OSStatus {
        if handler != nil { self.deliver = deliver; return noErr }
        self.deliver = deliver
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(GetEventDispatcherTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == CarbonHotkeyRegistrar.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(pointer).takeUnretainedValue().deliver?(key.id)
            return noErr
        }, 1, &type, context, &handler)
    }

    func enabledSystemShortcuts() throws -> Set<KeyboardShortcut> {
        var value: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&value)
        guard status == noErr, let entries = value?.takeRetainedValue() as? [[String: Any]] else {
            throw Hotkeys.Failure.systemCheck(status == noErr ? OSStatus(paramErr) : status)
        }
        return Self.enabledShortcuts(in: entries)
    }

    static func enabledShortcuts(in entries: [[String: Any]]) -> Set<KeyboardShortcut> {
        Set(entries.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber else { return nil }
            // Keep Fn and other flags intact; dropping them creates false conflicts.
            return KeyboardShortcut(keyCode: code.uint32Value, modifiers: modifiers.uint32Value)
        })
    }

    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: eventID), GetEventDispatcherTarget(),
            OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { refs[eventID] = ref; return noErr }
        return status == noErr ? OSStatus(eventHotKeyInvalidErr) : status
    }
    func unregister(eventID: UInt32) {
        if let ref = refs.removeValue(forKey: eventID) { UnregisterEventHotKey(ref) }
    }
    func stop() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        deliver = nil
    }
    deinit { stop() }
}
