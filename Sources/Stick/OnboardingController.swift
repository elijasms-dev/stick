import AppKit
import ApplicationServices
import QuartzCore

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
    private var shortcutConfiguration: ShortcutConfiguration
    private var shortcutLabels: [ShortcutAction: NSTextField] = [:]
    private var titleLabel: NSTextField!
    private var descriptionLabel: NSTextField!
    private var statusIcon: NSImageView!
    private var statusLabel: NSTextField!
    private var explanationLabel: NSTextField!
    private var shortcuts: NSStackView!
    private var detailLabel: NSTextField!
    private var helpButton: NSButton!
    private var helpContent: NSStackView!
    private var settingsError: NSTextField!
    private var primaryButton: NSButton!
    private var permissionContent: NSStackView!

    init(configuration: ShortcutConfiguration = .defaults,
         checkAccess: @escaping () -> Bool = { AXIsProcessTrusted() },
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
        self.shortcutConfiguration = configuration
        self.requestAccess = requestAccess
        self.openSettings = openSettings
        self.revealApp = revealApp
        self.onFinish = onFinish
        self.onShowNotes = onShowNotes
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set up Stick"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NoteStyle.paper
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        stage = checkAccess() ? .ready : .needsAccess
        buildContent()
        updateContent()
        fitWindowToScreen()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateShortcuts(_ configuration: ShortcutConfiguration) {
        shortcutConfiguration = configuration
        for (action, key) in [(ShortcutAction.addNote, configuration.addNote), (.togglePins, configuration.togglePins)] {
            shortcutLabels[action]?.stringValue = key.displayString
            shortcutLabels[action]?.setAccessibilityLabel(key.spokenString)
        }
    }

    func present() {
        refreshPermission()
        fitWindowToScreen()
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
        // Keep the same controls and window in place as permission changes.
        updateContent(revealReady: stage == .ready)
    }

    @objc func performPrimaryAction() {
        let previous = stage
        refreshPermission()
        // A click belongs to the action the user saw, even if permission just changed.
        // In particular, an "Open Settings" click must not silently finish setup.
        guard previous == stage else { return }
        switch stage {
        case .needsAccess:
            requestedAccess = true
            stage = .waiting
            updateContent()
            // The system prompt offers Settings. Do not also open a second Settings flow.
            requestAccess()
            refreshPermission()
        case .waiting:
            let failed = !openSettings()
            if failed != settingsFailed {
                settingsFailed = failed
                updateContent()
            }
        case .ready:
            close()
            onFinish()
        }
    }

    @objc private func showSavedNotes() { close(); onShowNotes() }
    @objc private func toggleHelp() {
        helpExpanded.toggle()
        updateContent(revealHelp: helpExpanded)
        if helpExpanded {
            window?.contentView?.layoutSubtreeIfNeeded()
            helpContent.scrollToVisible(helpContent.bounds)
        }
    }
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
        stack.detachesHiddenViews = true
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

    private func shortcut(_ title: String, keys: String, spokenKeys: String, action: ShortcutAction? = nil) -> NSView {
        let name = NoteStyle.label(title, size: 13, weight: .medium)
        let key = NoteStyle.label(keys, size: 14, weight: .medium, color: NoteStyle.accent)
        key.setAccessibilityLabel(spokenKeys)
        if let action { shortcutLabels[action] = key }
        key.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [name, NSView(), key])
        row.spacing = 12
        return row
    }

    private func buildContent() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root
        let logo = NSImageView(image: StickBrand.image(size: 26))
        logo.setAccessibilityElement(false)
        logo.widthAnchor.constraint(equalToConstant: 26).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let brand = NSStackView(views: [logo,
                                      NoteStyle.label("Stick", size: 16, weight: .semibold), NSView()])
        brand.spacing = 9
        titleLabel = copy("", size: 27, color: .labelColor)
        titleLabel.font = .systemFont(ofSize: 27, weight: .semibold)
        descriptionLabel = copy("")
        let heading = vertical([titleLabel, descriptionLabel], spacing: 8)

        statusIcon = symbol("accessibility", size: 17, color: NoteStyle.accent)
        statusLabel = NoteStyle.label("", size: 12)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        let status = NSStackView(views: [statusIcon,
                                        NoteStyle.label("Accessibility", size: 13, weight: .semibold), NSView(),
                                        statusLabel])
        status.spacing = 8
        explanationLabel = copy("", size: 13)
        let divider = NSBox(); divider.boxType = .separator
        shortcuts = vertical([divider,
                              shortcut("Add a note to selected text", keys: shortcutConfiguration.addNote.displayString,
                                       spokenKeys: shortcutConfiguration.addNote.spokenString, action: .addNote),
                              shortcut("Show or hide your pins", keys: shortcutConfiguration.togglePins.displayString,
                                       spokenKeys: shortcutConfiguration.togglePins.spokenString, action: .togglePins),
                              shortcut("Close a note and return", keys: "esc", spokenKeys: "Escape")], spacing: 14)
        let card = inset(vertical([status, explanationLabel, shortcuts], spacing: 14))
        detailLabel = copy("", size: 12)
        detailLabel.setAccessibilityLabel("Setup status")
        permissionContent = vertical([heading, card, detailLabel], spacing: 20)

        helpButton = NSButton(title: "Need help with access?", target: self, action: #selector(toggleHelp))
        helpButton.isBordered = false
        helpButton.contentTintColor = NoteStyle.accent
        helpButton.font = .systemFont(ofSize: 12)
        helpButton.alignment = .left
        let instructions = copy("If Stick is missing, use + in the permission list to add this app. If Stick is already on but access isn’t detected, remove its entry and add this copy again, then quit and reopen Stick.", size: 12)
        let locate = NoteStyle.button("Show Stick in Finder", target: self, action: #selector(showAppInFinder))
        helpContent = vertical([instructions, locate], spacing: 10)
        settingsError = copy("Couldn’t open Settings. Open System Settings, choose Privacy & Security, then find the Accessibility permission list.", size: 12, color: .systemRed)
        let stack = vertical([brand, permissionContent, helpButton, helpContent, settingsError], spacing: 20)
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
        primaryButton = NoteStyle.button("", target: self, action: #selector(performPrimaryAction))
        primaryButton.bezelColor = NoteStyle.actionFill
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [notes, NSView(), primaryButton])
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
        window.initialFirstResponder = primaryButton
    }

    private func updateContent(revealReady: Bool = false, revealHelp: Bool = false) {
        let ready = stage == .ready
        titleLabel.stringValue = ready ? "You’re ready." : "Let Stick find your place."
        descriptionLabel.stringValue = ready
            ? "Select a passage in a document. Leave a note there, and pick up where you left off."
            : "Allow Accessibility access to attach notes to text in the apps you use."
        statusIcon.image = NSImage(systemSymbolName: ready ? "checkmark.circle.fill" : "accessibility", accessibilityDescription: nil)
        statusIcon.contentTintColor = ready ? .systemGreen : NoteStyle.accent
        statusLabel.stringValue = ready ? "Enabled" : stage == .waiting ? "Waiting for access" : "Not enabled"
        statusLabel.textColor = ready ? .labelColor : .secondaryLabelColor
        explanationLabel.stringValue = stage == .waiting
            ? "In System Settings, turn on Stick. macOS may ask you to confirm with Touch ID or your password."
            : "Stick reads document text and selection positions so your pins can follow the right passage."
        explanationLabel.isHidden = ready
        shortcuts.isHidden = !ready
        detailLabel.stringValue = ready ? "Stick lives in your menu bar. Your notes save as you type."
            : stage == .waiting ? "This window updates automatically when access is enabled."
            : "Your notes and saved text stay on this Mac. No account needed."
        helpButton.title = helpExpanded ? "Hide help" : "Need help with access?"
        helpButton.setAccessibilityExpanded(helpExpanded)
        helpButton.isHidden = ready
        helpContent.isHidden = ready || !helpExpanded
        settingsError.isHidden = !settingsFailed
        primaryButton.title = ready ? "Start using Stick" : stage == .waiting ? "Open System Settings" : "Enable Accessibility…"
        window?.contentView?.layoutSubtreeIfNeeded()

        // Only recover focus if its control disappeared. Never activate over Settings,
        // or replace the user's focus during a retry or ordinary permission polling.
        if let window, window.isKeyWindow,
           let focused = window.firstResponder as? NSView, focused.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(primaryButton)
        }
        if revealReady { reveal(permissionContent) }
        if revealHelp { reveal(helpContent) }
    }

    private func reveal(_ view: NSView) {
        guard window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = 1
            return
        }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
    }

    private func fitWindowToScreen() {
        guard let window else { return }
        let available = (window.screen ?? NSScreen.main)?.visibleFrame
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: 500, height: min(560, (available?.height ?? 900) - chrome)))
        var origin = NSPoint(x: window.frame.minX, y: top - window.frame.height)
        if let available {
            origin.x = max(available.minX, min(origin.x, available.maxX - window.frame.width))
            origin.y = max(available.minY, min(origin.y, available.maxY - window.frame.height))
        }
        window.setFrameOrigin(origin)
    }
}
