import AppKit
import ApplicationServices
import StickCore

@MainActor
final class StickAppDelegate: NSObject, NSApplicationDelegate {
    private var store: NoteStore?
    private let queue = DispatchQueue(label: "dev.elijasms.stick.accessibility", qos: .userInitiated)
    private let hotkeys = Hotkeys()
    private var status: NSStatusItem!
    private let overlays = PinOverlayController()
    private var editor: NoteEditorController?
    private var list: NotesListController?
    private var timer: Timer?
    private var busy = false
    private var capturing = false
    private var visible = false
    private var sourcePID: pid_t?
    private var observedContext: DocumentContext?
    private var unplaced = Set<UUID>()
    private var pendingReattach: UUID?
    private var activationObserver: NSObjectProtocol?
    private var welcome: NSWindowController?
    private var generation = 0
    private var failureShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try NoteStore() } catch { alert("Couldn’t load your notes", error.localizedDescription) }
        sourcePID = externalApp()?.processIdentifier
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "pin.circle", accessibilityDescription: "Stick")
        rebuildMenu()
        hotkeys.onPress = { [weak self] id in
            Task { @MainActor in
                if id == 1 { self?.addNote() } else { self?.togglePins() }
            }
        }
        do { try hotkeys.start() } catch { alert("Shortcut unavailable", error.localizedDescription) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                guard let self else { return }
                self.sourcePID = app.processIdentifier
                self.generation += 1
                self.overlays.hide()
                self.observedContext = nil
                if self.visible { self.refreshPins() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.visible == true { self?.refreshPins() } }
        }
        if !UserDefaults.standard.bool(forKey: "welcomeShown") || !AXIsProcessTrusted() { showWelcome() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); hotkeys.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private func externalApp() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front
    }
    private func targetPID() -> pid_t? { externalApp()?.processIdentifier ?? sourcePID }

    private func rebuildMenu() {
        let menu = NSMenu()
        for (title, action, key) in [("Add note to selection", #selector(addNote), "n"), (visible ? "Hide pins" : "Show pins", #selector(togglePins), "p")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .option]; item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "All Notes…", action: #selector(showNotes), keyEquivalent: "")
        all.target = self; menu.addItem(all)
        let help = NSMenuItem(title: "Getting Started…", action: #selector(showWelcome), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        if pendingReattach != nil {
            let cancel = NSMenuItem(title: "Cancel reattaching note", action: #selector(cancelReattach), keyEquivalent: "")
            cancel.target = self; menu.addItem(cancel)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit); status.menu = menu
        status.button?.toolTip = visible ? "Stick — pins visible" : "Stick — Control–Option–N adds a note"
    }

    private func permissionReady() -> Bool {
        if AXIsProcessTrusted() { return true }
        showWelcome(); return false
    }

    @objc private func addNote() {
        guard store != nil, permissionReady(), !capturing, let pid = targetPID() else { return }
        // A user request queues behind an in-flight scan instead of being dropped.
        sourcePID = pid; capturing = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try AccessibilityEngine().captureSelection(pid: pid) }
            DispatchQueue.main.async { [self] in
                self.capturing = false
                switch result {
                case .failure(let error): self.alert("Select some text first", error.localizedDescription)
                case .success(let captured):
                    let c = captured.context
                    var note: StickNote
                    if let id = self.pendingReattach, let old = self.store?.notes.first(where: { $0.id == id }) {
                        note = old
                        note.appBundleID = c.appBundleID; note.appName = c.appName
                        note.documentID = c.documentID; note.documentTitle = c.documentTitle; note.anchor = captured.anchor
                        note.updatedAt = Date(); self.pendingReattach = nil; self.unplaced.remove(id)
                    } else {
                        note = StickNote(body: "", appBundleID: c.appBundleID, appName: c.appName, documentID: c.documentID, documentTitle: c.documentTitle, anchor: captured.anchor)
                    }
                    guard self.save(note) else { return }
                    self.observedContext = c
                    self.openEditor(note, point: self.cocoaRect(captured.bounds).origin)
                    self.rebuildMenu()
                }
            }
        }
    }

    @objc private func togglePins() {
        guard permissionReady() else { return }
        visible.toggle(); generation += 1
        if visible { refreshPins() } else { overlays.hide() }
        rebuildMenu()
    }

    private func refreshPins() {
        guard visible, !busy, !capturing, AXIsProcessTrusted(), let store, let pid = targetPID() else { return }
        busy = true
        let notes = store.notes, token = generation
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try AccessibilityEngine().resolve(notes: notes, pid: pid) }
            DispatchQueue.main.async { [self] in
                self.busy = false
                guard self.visible, token == self.generation else { return }
                switch result {
                case .failure:
                    self.overlays.hide()
                case .success(let (context, locations)):
                    self.observedContext = context
                    var pins: [(id: UUID, rect: CGRect, label: String)] = []
                    for note in notes where note.appBundleID == context.appBundleID && note.documentID == context.documentID {
                        switch locations[note.id] {
                        case .visible(let bounds):
                            self.unplaced.remove(note.id)
                            pins.append((note.id, self.cocoaRect(bounds), note.body.isEmpty ? note.anchor.quote : note.body))
                        case .missing, .ambiguous: self.unplaced.insert(note.id)
                        case .offscreen: self.unplaced.remove(note.id)
                        case nil: break
                        }
                    }
                    self.overlays.show(pins: pins) { [weak self] id in self?.openNote(id) }
                    self.list?.update(notes: self.store?.notes ?? [], unplaced: self.unplaced)
                }
            }
        }
    }

    private func cocoaRect(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    @discardableResult private func save(_ note: StickNote) -> Bool {
        do {
            try store?.upsert(note); failureShown = false
            list?.update(notes: store?.notes ?? [], unplaced: unplaced)
            return true
        } catch {
            if !failureShown { failureShown = true; alert("Your changes couldn’t be saved", error.localizedDescription + " Keep the note open and copy your text before quitting.") }
            return false
        }
    }
    private func delete(_ id: UUID) {
        do {
            try store?.delete(id: id)
            if editor?.noteID == id { editor?.close(); editor = nil }
            if pendingReattach == id { pendingReattach = nil; rebuildMenu() }
            unplaced.remove(id); list?.update(notes: store?.notes ?? [], unplaced: unplaced)
            generation += 1; refreshPins()
        }
        catch { alert("Couldn’t delete note", error.localizedDescription) }
    }
    private func openNote(_ id: UUID) {
        guard let note = store?.notes.first(where: { $0.id == id }) else { return }
        openEditor(note, point: nil)
    }
    private func openEditor(_ note: StickNote, point: NSPoint?) {
        editor?.close()
        editor = NoteEditorController(note: note, onChange: { [weak self] in _ = self?.save($0) }, onDelete: { [weak self] in self?.delete($0) }, onClose: { [weak self] in
            guard let self, let pid = self.sourcePID else { return }
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        })
        editor?.present(near: point)
    }

    @objc private func showNotes() {
        if list == nil {
            list = NotesListController(onOpen: { [weak self] in self?.openNote($0) }, onReveal: { [weak self] in self?.openSource($0) }, onReattach: { [weak self] id in
                guard let self else { return }
                self.pendingReattach = id; self.rebuildMenu(); self.list?.close()
                self.alert("Choose a new location", "Select the text you want to attach this note to, then press Control–Option–N. Your note will keep its existing text.")
                if let pid = self.sourcePID { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps]) }
            }, onDelete: { [weak self] in self?.delete($0) })
        }
        list?.update(notes: store?.notes ?? [], unplaced: unplaced); list?.present()
    }

    private func openSource(_ id: UUID) {
        guard let note = store?.notes.first(where: { $0.id == id }) else { return }
        visible = true; generation += 1; list?.close(); rebuildMenu()
        if let url = URL(string: note.documentID), ["file", "http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: note.appBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { self.alert("Couldn’t open document", error.localizedDescription) } }
            }
        } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: note.appBundleID).first {
            app.activate(options: [.activateIgnoringOtherApps])
        } else { alert("Open the original document", "This app didn’t provide a document address. Open \(note.documentTitle) in \(note.appName), then reveal pins.") }
    }

    @objc private func cancelReattach() { pendingReattach = nil; rebuildMenu() }

    @objc private func showWelcome() {
        if let welcome { welcome.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Welcome to Stick"; panel.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Leave a thought where it belongs.")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let copy = NSTextField(wrappingLabelWithString: "Select text in your document, then press Control–Option–N to add a note.\n\nControl–Option–P reveals or hides the pins in your current document. Click a pin to open its note. Escape returns you to work.\n\nStick uses Accessibility to locate your selections. Notes stay on this Mac.")
        copy.font = .systemFont(ofSize: 14)
        let settings = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
        settings.bezelStyle = .rounded
        let done = NSButton(title: "Get Started", target: self, action: #selector(dismissWelcome)); done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        [title, copy, settings, done].forEach(stack.addArrangedSubview)
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24)])
        welcome = NSWindowController(window: panel); panel.center(); welcome?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc private func dismissWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeShown"); welcome?.close()
    }
    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
