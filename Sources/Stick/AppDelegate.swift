import AppKit
import ApplicationServices
import OSLog
import StickCore

@MainActor
final class StickAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "dev.elijasms.stick", category: "commands")
    private var store: NoteStore?
    private let queue = DispatchQueue(label: "dev.elijasms.stick.accessibility", qos: .userInitiated)
    private let engine = AccessibilityEngine()
    private var observation: AccessibilityObservation!
    private var motionMonitor: Any?
    private var scheduledRefresh: DispatchWorkItem?
    private var refreshAgain = false
    private var lastRefresh = Date.distantPast
    private var geometryRevision = 0
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
    private var welcome: OnboardingController?
    private var onboardingReturnPID: pid_t?
    private var accessibilityTrusted = AXIsProcessTrusted()
    private var generation = 0
    private var failureShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditingMenu()
        do { store = try NoteStore() } catch { alert("Couldn’t load your notes", error.localizedDescription) }
        sourcePID = externalApp()?.processIdentifier
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = StickBrand.image(size: 18, template: true)
        NSApp.applicationIconImage = StickBrand.appIcon(size: 256)
        rebuildMenu()
        observation = AccessibilityObservation { [weak self] structural in
            guard let self, self.visible else { return }
            self.geometryRevision += 1
            if structural { self.generation += 1; self.overlays.hide() }
            self.requestPinRefresh()
        }
        // Wheel/drag events keep geometry responsive in apps that omit AX scroll notifications.
        // No key events or typed content are observed here.
        motionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { [weak self] _ in
            guard let self, self.visible else { return }
            self.geometryRevision += 1
            self.requestPinRefresh()
        }
        hotkeys.onPress = { [weak self] id in
            Task { @MainActor in
                self?.logger.notice("Global shortcut received: \(id)")
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
                if self.visible { self.requestPinRefresh() }
            }
        }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkPermissionChanges()
                if self.visible { self.requestPinRefresh() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if !UserDefaults.standard.bool(forKey: "welcomeShown") || !AXIsProcessTrusted() { showWelcome() }
        else { showNotes() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); hotkeys.stop(); scheduledRefresh?.cancel()
        if let motionMonitor { NSEvent.removeMonitor(motionMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor?.flushChanges() == false ? .terminateCancel : .terminateNow
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        checkPermissionChanges()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AXIsProcessTrusted() || !UserDefaults.standard.bool(forKey: "welcomeShown") { showWelcome() }
        else { showNotes() }
        return true
    }

    private func checkPermissionChanges() {
        let trusted = AXIsProcessTrusted()
        welcome?.refreshPermission()
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted
        if !trusted {
            // Invalidate in-flight scans too: a late result must not restore old pins.
            generation += 1
            visible = false
            overlays.hide()
            scheduledRefresh?.cancel(); scheduledRefresh = nil
            let engine = self.engine, observation = self.observation
            queue.async { observation?.stop(); engine.resetTracking() }
            observedContext = nil
            rebuildMenu()
        }
    }

    private func installEditingMenu() {
        // Standard responder-chain commands also supply keyboard shortcuts while
        // editing a note in this accessory app.
        let main = NSMenu()
        let application = NSMenuItem(); application.submenu = NSMenu(title: "Stick")
        application.submenu?.addItem(withTitle: "Quit Stick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(application)
        let notes = NSMenuItem(); notes.submenu = NSMenu(title: "Notes")
        for (title, action, key) in [
            ("Add note to selection", #selector(addNote), "n"),
            (visible ? "Hide pins" : "Show pins", #selector(togglePins), "p")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .option]; item.target = self
            notes.submenu?.addItem(item)
        }
        let all = NSMenuItem(title: "All Notes…", action: #selector(showNotes), keyEquivalent: "")
        all.target = self; notes.submenu?.addItem(all)
        main.addItem(notes)
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] { edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.submenu?.insertItem(redo, at: 1)
        main.addItem(edit)
        NSApp.mainMenu = main
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
        installEditingMenu()
    }

    private func permissionReady() -> Bool {
        checkPermissionChanges()
        if accessibilityTrusted { return true }
        logger.notice("Command needs Accessibility permission")
        showWelcome(); return false
    }

    @objc private func addNote() {
        guard store != nil, permissionReady(), !capturing, let pid = targetPID() else { return }
        // A user request queues behind an in-flight scan instead of being dropped.
        sourcePID = pid; capturing = true
        let engine = self.engine
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try engine.captureSelection(pid: pid) }
            DispatchQueue.main.async { [self] in
                self.capturing = false
                defer { if self.refreshAgain { self.requestPinRefresh() } }
                guard self.permissionReady() else { return }
                switch result {
                case .failure(let error): self.alert("Select some text first", error.localizedDescription)
                case .success(let captured):
                    let c = captured.context
                    var note: StickNote
                    if let id = self.pendingReattach, let old = self.store?.notes.first(where: { $0.id == id }) {
                        note = old
                        note.appBundleID = c.appBundleID; note.appName = c.appName
                        note.documentID = c.documentID; note.documentTitle = c.documentTitle; note.anchor = captured.anchor
                        note.updatedAt = Date()
                    } else {
                        note = StickNote(body: "", appBundleID: c.appBundleID, appName: c.appName, documentID: c.documentID, documentTitle: c.documentTitle, anchor: captured.anchor)
                    }
                    guard self.save(note) else { return }
                    if self.pendingReattach == note.id {
                        self.pendingReattach = nil
                        self.unplaced.remove(note.id)
                        let reattachedID = note.id
                        self.queue.async { engine.forgetTracking(noteID: reattachedID) }
                    }
                    self.generation += 1
                    self.observedContext = c
                    self.openEditor(note, point: self.cocoaRect(captured.bounds).origin, returnPID: c.pid)
                    self.rebuildMenu()
                }
            }
        }
    }

    @objc private func togglePins() {
        guard permissionReady() else { return }
        visible.toggle(); generation += 1
        if visible { requestPinRefresh() }
        else {
            overlays.hide()
            scheduledRefresh?.cancel(); scheduledRefresh = nil
            let observation = self.observation
            queue.async { observation?.stop() }
        }
        rebuildMenu()
    }

    private func requestPinRefresh() {
        guard visible else { return }
        if busy || capturing { refreshAgain = true; return }
        guard scheduledRefresh == nil else { return }
        let delay = max(0, 0.05 - Date().timeIntervalSince(lastRefresh))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledRefresh = nil
            self.refreshPins()
        }
        scheduledRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshPins() {
        guard visible, !busy, !capturing, AXIsProcessTrusted(), let store, let pid = targetPID() else { return }
        busy = true; refreshAgain = false; lastRefresh = Date()
        let notes = store.notes, token = generation
        let geometryToken = geometryRevision
        let engine = self.engine, observation = self.observation
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try engine.resolve(notes: notes, pid: pid) }
            let anchorUpdates = engine.takeAnchorUpdates()
            DispatchQueue.main.async { [self] in
                self.busy = false
                defer { if self.refreshAgain { self.requestPinRefresh() } }
                guard self.visible, token == self.generation, AXIsProcessTrusted() else { return }
                switch result {
                case .failure:
                    self.overlays.hide()
                case .success(let (context, locations)):
                    do {
                        try self.store?.updateAnchors(anchorUpdates, expected: Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.anchor) }))
                    } catch {
                        self.logger.error("Could not save updated pin locations: \(error.localizedDescription)")
                    }
                    // Never paint coordinates captured before a newer scroll or edit.
                    guard geometryToken == self.geometryRevision else {
                        self.overlays.hide()
                        self.refreshAgain = true
                        return
                    }
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
            observation?.update(pid: pid, elements: engine.observationElements)
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
    @discardableResult private func delete(_ id: UUID) -> Bool {
        do {
            try store?.delete(id: id)
            if editor?.noteID == id { editor?.discardAndClose(); editor = nil }
            if pendingReattach == id { pendingReattach = nil; rebuildMenu() }
            unplaced.remove(id); list?.update(notes: store?.notes ?? [], unplaced: unplaced)
            generation += 1; requestPinRefresh()
            return true
        }
        catch { alert("Couldn’t delete note", error.localizedDescription); return false }
    }
    private func openNote(_ id: UUID) {
        guard let note = store?.notes.first(where: { $0.id == id }) else { return }
        let returnPID = NSRunningApplication.runningApplications(withBundleIdentifier: note.appBundleID).first?.processIdentifier
        openEditor(note, point: nil, returnPID: returnPID)
    }
    private func openEditor(_ note: StickNote, point: NSPoint?, returnPID: pid_t?) {
        guard editor?.flushChanges() != false else { return }
        editor?.close()
        // Reopening the same note after a pending save uses its latest body.
        let currentNote = store?.notes.first(where: { $0.id == note.id }) ?? note
        editor = NoteEditorController(note: currentNote, onChange: { [weak self] edited in
            guard let self, var latest = self.store?.notes.first(where: { $0.id == edited.id }) else { return false }
            latest.body = edited.body; latest.updatedAt = edited.updatedAt
            return self.save(latest)
        }, onDelete: { [weak self] in self?.delete($0) ?? false }, onClose: {
            // Returning to work belongs to this editor's source, even if another
            // app becomes active while the note remains open.
            guard let returnPID, let sourceApp = NSRunningApplication(processIdentifier: returnPID),
                  sourceApp.bundleIdentifier == note.appBundleID, !sourceApp.isTerminated else { return }
            sourceApp.activate(options: [.activateIgnoringOtherApps])
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
        if welcome?.window?.isVisible != true {
            let app = externalApp() ?? sourcePID.flatMap { NSRunningApplication(processIdentifier: $0) }
            onboardingReturnPID = app?.bundleIdentifier == "com.apple.systempreferences" ? nil : app?.processIdentifier
        }
        if welcome == nil {
            welcome = OnboardingController(onFinish: { [weak self] in
                guard let self, AXIsProcessTrusted() else { return }
                UserDefaults.standard.set(true, forKey: "welcomeShown")
                if let pid = self.onboardingReturnPID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
                    app.activate(options: [.activateIgnoringOtherApps])
                } else { self.showNotes() }
            }, onShowNotes: { [weak self] in self?.showNotes() })
        }
        welcome?.present()
    }
    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
