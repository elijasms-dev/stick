import ApplicationServices
import Foundation

/// Registration is confined to the AX worker queue. The immutable callback is
/// delivered on the main actor; it never performs AX reads. The app retains this
/// object for its lifetime, including while observer callbacks are in flight.
final class AccessibilityObservation: @unchecked Sendable {
    private let onChange: @MainActor @Sendable (Bool) -> Void
    private var observer: AXObserver?
    private var pid: pid_t?
    private var watched: [AXUIElement] = []

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) { self.onChange = onChange }

    func update(pid: pid_t, elements: [AXUIElement]) {
        if self.pid != pid {
            stop()
            self.pid = pid
            var created: AXObserver?
            let result = AXObserverCreate(pid, { _, _, notification, context in
                guard let context else { return }
                let owner = Unmanaged<AccessibilityObservation>.fromOpaque(context).takeUnretainedValue()
                let name = notification as String
                let structural = ["AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXUIElementDestroyed"].contains(name)
                let callback = owner.onChange
                DispatchQueue.main.async { callback(structural) }
            }, &created)
            guard result == .success, let created else { return }
            observer = created
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        guard let observer else { return }
        let names = ["AXFocusedWindowChanged", "AXFocusedUIElementChanged", "AXWindowMoved",
                     "AXWindowResized", "AXValueChanged", "AXSelectedTextChanged", "AXLayoutChanged"]
        // Keep registrations tied to the current document, not every visited window.
        for old in watched where !elements.contains(where: { CFEqual($0, old) }) {
            for name in names { AXObserverRemoveNotification(observer, old, name as CFString) }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for element in elements where !watched.contains(where: { CFEqual($0, element) }) {
            for name in names {
                // Unsupported notifications are normal; polling remains available.
                AXObserverAddNotification(observer, element, name as CFString, context)
            }
        }
        watched = elements
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        watched.removeAll()
        pid = nil
    }
}
