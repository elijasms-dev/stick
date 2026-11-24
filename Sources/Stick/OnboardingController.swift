import AppKit
import ApplicationServices

private final class OnboardingBody: NSView {
    override var isFlipped: Bool { true }
}

/// The system remains the authority for permission. Requesting it never completes setup.
@MainActor
final class OnboardingController: NSWindowController, NSWindowDelegate {
    enum Stage { case needsAccess, waiting, ready }
    private(set) var stage: Stage = .needsAccess
    private var requestedAccess = false
    private var helpExpanded = false
    private var settingsFailed = false
    private var monitor: Timer?
    private let checkAccess: () -> Bool
    private let requestAccess: () -> Void
    private let openSettings: () -> Bool
    private let revealApp: () -> Void
    private let onFinish: () -> Void
    private let onShowNotes: () -> Void

    init(checkAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
         requestAccess: @escaping () -> Void = {
             let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
             _ = AXIsProcessTrustedWithOptions(options)
         },
         openSettings: @escaping () -> Bool = {
             guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return false }
             return NSWorkspace.shared.open(url)
         },
         revealApp: @escaping () -> Void = { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
         onFinish: @escaping () -> Void, onShowNotes: @escaping () -> Void) {
        self.checkAccess = checkAccess
        self.requestAccess = requestAccess
        self.openSettings = openSettings
        self.revealApp = revealApp
        self.onFinish = onFinish
        self.onShowNotes = onShowNotes
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up Stick"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NoteStyle.paper
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        stage = checkAccess() ? .ready : .needsAccess
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        refreshPermission()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if monitor == nil {
            let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshPermission() }
            }
            RunLoop.main.add(timer, forMode: .common)
            monitor = timer
        }
    }

    func refreshPermission() {
        let updated: Stage = checkAccess() ? .ready : requestedAccess ? .waiting : .needsAccess
        guard updated != stage else { return }
        stage = updated
        settingsFailed = false
        if stage == .ready { helpExpanded = false }
        // Update in place; never activate Stick over System Settings as access changes.
        buildContent()
    }

    @objc func performPrimaryAction() {
        let previous = stage
        refreshPermission()
        // A click on a stale "Start using Stick" button must not finish setup.
        if previous == .ready && stage != .ready { return }
        switch stage {
        case .needsAccess:
            requestedAccess = true
            stage = .waiting
            buildContent()
            // The system prompt offers Settings. Do not also open a second Settings flow.
            requestAccess()
            refreshPermission()
        case .waiting:
            settingsFailed = !openSettings()
            buildContent()
        case .ready:
            close()
            onFinish()
        }
    }

    @objc private func showSavedNotes() { close(); onShowNotes() }
    @objc private func toggleHelp() { helpExpanded.toggle(); buildContent(focusHelp: true) }
    @objc private func showAppInFinder() { revealApp() }

    func windowWillClose(_ notification: Notification) {
        monitor?.invalidate()
        monitor = nil
    }

    private func copy(_ text: String, size: CGFloat = 14, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        view.symbolConfiguration = .init(pointSize: size, weight: .medium)
        view.contentTintColor = color
        view.setAccessibilityElement(false)
        return view
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func inset(_ view: NSView) -> NSView {
        let surface = NoteSurface()
        view.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
            view.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18),
            view.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -18)
        ])
        return surface
    }

    private func shortcut(_ title: String, keys: String, spokenKeys: String) -> NSView {
        let name = NoteStyle.label(title, size: 13, weight: .medium)
        let key = NoteStyle.label(keys, size: 14, weight: .medium, color: NoteStyle.accent)
        key.setAccessibilityLabel(spokenKeys)
        key.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [name, NSView(), key])
        row.spacing = 12
        return row
    }

    private func buildContent(focusHelp: Bool = false) {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        let ready = stage == .ready
        let brand = NSStackView(views: [symbol("note.text", size: 22, color: NoteStyle.accent),
                                      NoteStyle.label("Stick", size: 16, weight: .semibold), NSView()])
        brand.spacing = 9
        let title = copy(ready ? "You’re ready." : "Let Stick find your place.", size: 27, color: .labelColor)
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        let description = copy(ready
            ? "Select a passage in a document. Leave a note there, and pick up where you left off."
            : "Allow Accessibility access to attach notes to text in the apps you use.")
        let heading = vertical([title, description], spacing: 8)

        let status = NSStackView(views: [symbol(ready ? "checkmark.circle.fill" : "accessibility", size: 17,
                                               color: ready ? .systemGreen : NoteStyle.accent),
                                        NoteStyle.label("Accessibility", size: 13, weight: .semibold), NSView(),
                                        NoteStyle.label(ready ? "Enabled" : "Not enabled", size: 12,
                                                        color: ready ? .labelColor : .secondaryLabelColor)])
        status.spacing = 8
        let card: NSView
        if ready {
            let divider = NSBox(); divider.boxType = .separator
            card = inset(vertical([status, divider,
                                   shortcut("Add a note to selected text", keys: "⌃ ⌥ N", spokenKeys: "Control Option N"),
                                   shortcut("Show or hide your pins", keys: "⌃ ⌥ P", spokenKeys: "Control Option P"),
                                   shortcut("Close a note and return", keys: "esc", spokenKeys: "Escape")], spacing: 16))
        } else {
            let explanation = copy(stage == .waiting
                ? "In System Settings, turn on Stick. macOS may ask you to confirm with Touch ID or your password."
                : "Stick reads document text and selection positions so your pins can follow the right passage.", size: 13)
            card = inset(vertical([status, explanation], spacing: 12))
        }

        let detail = copy(ready ? "Stick lives in your menu bar. Your notes save as you type."
            : stage == .waiting ? "Waiting for access… This window updates automatically."
            : "Your notes and saved text stay on this Mac. No account needed.", size: 12)
        detail.setAccessibilityLabel("Setup status")
        var sections: [NSView] = [brand, heading, card, detail]
        var helpControl: NSButton?
        if !ready {
            let help = NSButton(title: helpExpanded ? "Hide help" : "Need help with access?", target: self, action: #selector(toggleHelp))
            help.isBordered = false
            help.contentTintColor = NoteStyle.accent
            help.font = .systemFont(ofSize: 12)
            help.alignment = .left
            help.setAccessibilityExpanded(helpExpanded)
            helpControl = help
            sections.append(help)
            if helpExpanded {
                let instructions = copy("If Stick is missing, use + in the permission list to add this app. If Stick is already on but access isn’t detected, remove its entry and add this copy again, then quit and reopen Stick.", size: 12)
                let locate = NoteStyle.button("Show Stick in Finder", target: self, action: #selector(showAppInFinder))
                sections.append(vertical([instructions, locate], spacing: 10))
            }
        }
        if settingsFailed {
            sections.append(copy("Couldn’t open Settings. Open System Settings, choose Privacy & Security, then find the Accessibility permission list.", size: 12, color: .systemRed))
        }
        let stack = vertical(sections, spacing: 20)
        stack.setCustomSpacing(24, after: brand)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = OnboardingBody()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        root.addSubview(scroll)

        let notes = NSButton(title: "View saved notes", target: self, action: #selector(showSavedNotes))
        notes.isBordered = false
        notes.font = .systemFont(ofSize: 12)
        notes.contentTintColor = .secondaryLabelColor
        let primary = NoteStyle.button(ready ? "Start using Stick" : stage == .waiting ? "Open System Settings" : "Enable Accessibility…",
                                       target: self, action: #selector(performPrimaryAction))
        primary.bezelColor = NoteStyle.actionFill
        primary.controlSize = .large
        primary.keyEquivalent = "\r"
        let footer = NSStackView(views: [notes, NSView(), primary])
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -24),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        let top = window.frame.maxY
        let available = (window.screen ?? NSScreen.main)?.visibleFrame
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let desiredHeight: CGFloat = 460 + (helpExpanded ? 115 : 0) + (settingsFailed ? 65 : 0)
        window.setContentSize(NSSize(width: 500, height: min(desiredHeight, (available?.height ?? 900) - chrome)))
        var origin = NSPoint(x: window.frame.minX, y: top - window.frame.height)
        if let available {
            origin.x = max(available.minX, min(origin.x, available.maxX - window.frame.width))
            origin.y = max(available.minY, min(origin.y, available.maxY - window.frame.height))
        }
        window.setFrameOrigin(origin)
        if window.isKeyWindow { window.makeFirstResponder(focusHelp ? helpControl : primary) }
    }
}
