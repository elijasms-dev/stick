import AppKit
import Carbon

enum ShortcutAction: UInt32, CaseIterable {
    case addNote = 1
    case togglePins = 2

    var title: String {
        switch self {
        case .addNote: return "Add note to selection"
        case .togglePins: return "Show or hide pins"
        }
    }
}

struct ShortcutKey {
    let keyCode: UInt32
    fileprivate let fallback: String
    fileprivate let equivalent: String?

    var title: String { equivalent == nil ? translatedCharacter?.uppercased() ?? fallback : fallback }
    var menuKeyEquivalent: String { equivalent ?? translatedCharacter?.lowercased() ?? fallback.lowercased() }

    private var translatedCharacter: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKey, characters.count, &actualLength, &characters)
        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: actualLength)
    }
}

struct KeyboardShortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let allowedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    private var key: ShortcutKey? { Self.availableKeys.first { $0.keyCode == keyCode } }
    var displayString: String {
        let symbols: [(UInt32, String)] = [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
                                          (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + (key?.title ?? "Unknown key")
    }
    var spokenString: String {
        let names: [(UInt32, String)] = [(UInt32(controlKey), "Control"), (UInt32(optionKey), "Option"),
                                        (UInt32(shiftKey), "Shift"), (UInt32(cmdKey), "Command")]
        return (names.filter { modifiers & $0.0 != 0 }.map(\.1) + [key?.title ?? "Unknown key"]).joined(separator: " ")
    }
    var menuKeyEquivalent: String { key?.menuKeyEquivalent ?? "" }
    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    func validate(for action: ShortcutAction) throws {
        guard key != nil else { throw ShortcutValidationError.invalidKey(action) }
        guard modifiers & ~Self.allowedModifiers == 0,
              modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            throw ShortcutValidationError.modifierRequired(action)
        }
        let equivalent = menuKeyEquivalent.lowercased()
        let command = UInt32(cmdKey)
        if modifiers == command && [",", "q", "w", "z", "x", "c", "v", "a"].contains(equivalent)
            || modifiers == UInt32(cmdKey | shiftKey) && equivalent == "z" {
            throw ShortcutValidationError.stickCommand(action, self)
        }
    }

    static let availableKeys: [ShortcutKey] = {
        let letters: [(Int, String)] = [
            (kVK_ANSI_A,"A"),(kVK_ANSI_B,"B"),(kVK_ANSI_C,"C"),(kVK_ANSI_D,"D"),
            (kVK_ANSI_E,"E"),(kVK_ANSI_F,"F"),(kVK_ANSI_G,"G"),(kVK_ANSI_H,"H"),
            (kVK_ANSI_I,"I"),(kVK_ANSI_J,"J"),(kVK_ANSI_K,"K"),(kVK_ANSI_L,"L"),
            (kVK_ANSI_M,"M"),(kVK_ANSI_N,"N"),(kVK_ANSI_O,"O"),(kVK_ANSI_P,"P"),
            (kVK_ANSI_Q,"Q"),(kVK_ANSI_R,"R"),(kVK_ANSI_S,"S"),(kVK_ANSI_T,"T"),
            (kVK_ANSI_U,"U"),(kVK_ANSI_V,"V"),(kVK_ANSI_W,"W"),(kVK_ANSI_X,"X"),
            (kVK_ANSI_Y,"Y"),(kVK_ANSI_Z,"Z"),
            (kVK_ANSI_0,"0"),(kVK_ANSI_1,"1"),(kVK_ANSI_2,"2"),(kVK_ANSI_3,"3"),
            (kVK_ANSI_4,"4"),(kVK_ANSI_5,"5"),(kVK_ANSI_6,"6"),(kVK_ANSI_7,"7"),
            (kVK_ANSI_8,"8"),(kVK_ANSI_9,"9"),
            (kVK_ANSI_Minus,"−"),(kVK_ANSI_Equal,"="),(kVK_ANSI_LeftBracket,"["),
            (kVK_ANSI_RightBracket,"]"),(kVK_ANSI_Backslash,"\\"),(kVK_ANSI_Semicolon,";"),
            (kVK_ANSI_Quote,"'"),(kVK_ANSI_Comma,","),(kVK_ANSI_Period,"."),
            (kVK_ANSI_Slash,"/"),(kVK_ANSI_Grave,"`")
        ]
        var result = letters.map { ShortcutKey(keyCode: UInt32($0.0), fallback: $0.1, equivalent: nil) }
        let special: [(Int, String, String)] = [
            (kVK_Space,"Space"," "),(kVK_Tab,"Tab","\t"),(kVK_Return,"Return","\r"),
            (kVK_Escape,"Escape","\u{1b}"),(kVK_Delete,"Delete","\u{8}"),
            (kVK_LeftArrow,"Left arrow",String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
            (kVK_RightArrow,"Right arrow",String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            (kVK_UpArrow,"Up arrow",String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            (kVK_DownArrow,"Down arrow",String(UnicodeScalar(NSDownArrowFunctionKey)!))
        ]
        result += special.map { ShortcutKey(keyCode: UInt32($0.0), fallback: $0.1, equivalent: $0.2) }
        let functionCodes = [kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,
                             kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17,kVK_F18,kVK_F19,kVK_F20]
        result += functionCodes.enumerated().map {
            ShortcutKey(keyCode: UInt32($0.element), fallback: "F\($0.offset + 1)",
                        equivalent: String(UnicodeScalar(NSF1FunctionKey + $0.offset)!))
        }
        return result
    }()
}

struct ShortcutConfiguration: Codable, Equatable {
    var addNote: KeyboardShortcut
    var togglePins: KeyboardShortcut

    static let defaults = ShortcutConfiguration(
        addNote: KeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey)),
        togglePins: KeyboardShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey)))

    subscript(action: ShortcutAction) -> KeyboardShortcut {
        get { action == .addNote ? addNote : togglePins }
        set { if action == .addNote { addNote = newValue } else { togglePins = newValue } }
    }

    func validate() throws {
        for action in ShortcutAction.allCases { try self[action].validate(for: action) }
        guard addNote != togglePins else { throw ShortcutValidationError.duplicate(addNote) }
    }
}

enum ShortcutValidationError: LocalizedError {
    case invalidKey(ShortcutAction)
    case modifierRequired(ShortcutAction)
    case duplicate(KeyboardShortcut)
    case stickCommand(ShortcutAction, KeyboardShortcut)

    var errorDescription: String? {
        switch self {
        case .invalidKey(let action): return "Choose a supported key for \(action.title.lowercased())."
        case .modifierRequired(let action): return "Include Control, Option, or Command for \(action.title.lowercased()). Shift alone is not enough."
        case .duplicate(let shortcut): return "\(shortcut.displayString) is assigned to both actions. Choose a different combination for each."
        case .stickCommand(_, let shortcut): return "\(shortcut.displayString) is already used by a standard Stick command. Choose another combination."
        }
    }
}

struct ShortcutPreferences {
    static let storageKey = "keyboardShortcuts"
    private let defaults: UserDefaults
    private struct Envelope: Codable { let version: Int; let configuration: ShortcutConfiguration }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> ShortcutConfiguration {
        guard let data = defaults.data(forKey: Self.storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, (try? envelope.configuration.validate()) != nil else { return .defaults }
        return envelope.configuration
    }

    func save(_ configuration: ShortcutConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(Envelope(version: 1, configuration: configuration))
        defaults.set(data, forKey: Self.storageKey)
    }
}
