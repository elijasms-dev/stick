import AppKit
import ApplicationServices
import StickCore

// Read-only diagnostic path used to verify the same capture and resolution code as the app.
if CommandLine.arguments.contains("--check-selection"), let last = CommandLine.arguments.last, let pid = Int32(last) {
    do {
        let engine = AccessibilityEngine()
        let captured = try engine.captureSelection(pid: pid)
        let c = captured.context
        let note = StickNote(body: "Diagnostic", appBundleID: c.appBundleID, appName: c.appName, documentID: c.documentID, documentTitle: c.documentTitle, anchor: captured.anchor)
        let (_, locations) = try engine.resolve(notes: [note], pid: pid)
        print("Captured \(captured.anchor.quote.utf16.count) UTF-16 characters in \(c.appName).")
        print("Resolution: \(String(describing: locations[note.id]))")
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = StickAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // NSApplication.delegate is weak. Keep it alive throughout the event loop,
    // including optimized release builds.
    withExtendedLifetime(delegate) { app.run() }
}
