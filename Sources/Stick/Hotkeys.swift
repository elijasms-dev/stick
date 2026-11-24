import AppKit
import Carbon

final class Hotkeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var onPress: ((UInt32) -> Void)?

    func start() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == 0x5354494B, key.id == 1 || key.id == 2 else { return OSStatus(eventNotHandledErr) }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(pointer).takeUnretainedValue()
            hotkeys.onPress?(key.id)
            return noErr
        }, 1, &type, context, &handler)
        guard status == noErr else { throw Failure.registration(status) }
        do {
            try register(code: UInt32(kVK_ANSI_N), id: 1)
            try register(code: UInt32(kVK_ANSI_P), id: 2)
        } catch { stop(); throw error }
    }

    private func register(code: UInt32, id: UInt32) throws {
        var ref: EventHotKeyRef?
        let key = EventHotKeyID(signature: 0x5354494B, id: id)
        let status = RegisterEventHotKey(code, UInt32(controlKey | optionKey), key, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { throw Failure.registration(status) }
        refs.append(ref)
    }

    func stop() {
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    enum Failure: LocalizedError {
        case registration(OSStatus)
        var errorDescription: String? { "Stick could not register its shortcuts (error \(self)). Another app may already use Control–Option–N or Control–Option–P. Menu commands are still available." }
    }
    deinit { stop() }
}
