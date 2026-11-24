import AppKit
import Carbon

private final class ShortcutSettingsWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
private final class ShortcutChoiceRow: NSView {
    let action: ShortcutAction
    var onChange: (() -> Void)?
    private let keyChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preview = NoteStyle.label("", size: 14, weight: .medium, color: NoteStyle.accent)
    private var modifiers: [(UInt32, NSButton)] = []

    init(action: ShortcutAction, shortcut: KeyboardShortcut) {
        self.action = action
        super.init(frame: .zero)
        let title = NoteStyle.label(action.title, size: 14, weight: .semibold)
        let heading = NSStackView(views: [title, NSView(), preview])
        heading.spacing = 12
        preview.setContentHuggingPriority(.required, for: .horizontal)
        for (name, flag) in [("Control", UInt32(controlKey)), ("Option", UInt32(optionKey)),
                             ("Shift", UInt32(shiftKey)), ("Command", UInt32(cmdKey))] {
            let button = NSButton(checkboxWithTitle: name, target: self, action: #selector(choiceChanged))
            button.font = .systemFont(ofSize: 12)
            button.identifier = NSUserInterfaceItemIdentifier("shortcut-\(action.rawValue)-\(name.lowercased())")
            button.setAccessibilityLabel("\(action.title): \(name)")
            modifiers.append((flag, button))
        }
        for key in KeyboardShortcut.availableKeys {
            keyChoice.addItem(withTitle: key.title)
            keyChoice.lastItem?.tag = Int(key.keyCode)
        }
        keyChoice.identifier = NSUserInterfaceItemIdentifier("shortcut-\(action.rawValue)-key")
        keyChoice.setAccessibilityLabel("\(action.title): key")
        keyChoice.target = self
        keyChoice.action = #selector(choiceChanged)
        keyChoice.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let choices = NSStackView(views: modifiers.map(\.1) + [NSView(), keyChoice])
        choices.spacing = 12
        let stack = NSStackView(views: [heading, choices])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            choices.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        setShortcut(shortcut)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var shortcut: KeyboardShortcut {
        KeyboardShortcut(keyCode: UInt32(keyChoice.selectedItem?.tag ?? 0),
                         modifiers: modifiers.reduce(UInt32(0)) { result, entry in
                             entry.1.state == .on ? result | entry.0 : result
                         })
    }

    func setShortcut(_ shortcut: KeyboardShortcut) {
        for (flag, button) in modifiers { button.state = shortcut.modifiers & flag != 0 ? .on : .off }
        if !keyChoice.selectItem(withTag: Int(shortcut.keyCode)) {
            keyChoice.addItem(withTitle: "Key \(shortcut.keyCode)")
            keyChoice.lastItem?.tag = Int(shortcut.keyCode)
            keyChoice.select(keyChoice.lastItem)
        }
        updatePreview()
    }

    private func updatePreview() {
        preview.stringValue = shortcut.displayString
        preview.setAccessibilityLabel("\(action.title) shortcut: \(shortcut.spokenString)")
    }

    @objc private func choiceChanged() { updatePreview(); onChange?() }
}

/// Draft choices are applied as a pair. A failed registration leaves the draft
/// available for correction and keeps the previously saved configuration intact.
@MainActor
final class ShortcutSettingsController: NSWindowController, NSWindowDelegate {
    private(set) var savedConfiguration: ShortcutConfiguration
    private let onApply: (ShortcutConfiguration) -> String?
    private var rows: [ShortcutAction: ShortcutChoiceRow] = [:]
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var applyButton: NSButton!
    private var doneButton: NSButton!
    private var savedWarning: String?
    private var hasError = false

    var draftConfiguration: ShortcutConfiguration {
        ShortcutConfiguration(addNote: rows[.addNote]!.shortcut, togglePins: rows[.togglePins]!.shortcut)
    }

    init(configuration: ShortcutConfiguration, onApply: @escaping (ShortcutConfiguration) -> String?) {
        savedConfiguration = configuration
        self.onApply = onApply
        let window = ShortcutSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Stick Settings"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NoteStyle.paper
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in self?.close() }
        buildContent()
        update(configuration: configuration)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(configuration: ShortcutConfiguration, warning: String? = nil) {
        savedConfiguration = configuration
        savedWarning = warning
        for action in ShortcutAction.allCases { rows[action]?.setShortcut(configuration[action]) }
        setFeedback(warning ?? "", isError: warning != nil)
        updateActionState()
    }

    @objc func applyChanges() {
        let candidate = draftConfiguration
        do { try candidate.validate() }
        catch {
            setFeedback(error.localizedDescription, isError: true)
            updateActionState()
            return
        }
        if let error = onApply(candidate) {
            setFeedback(error, isError: true)
            updateActionState()
            return
        }
        savedConfiguration = candidate
        savedWarning = nil
        setFeedback("Shortcuts saved.", isError: false)
        updateActionState()
    }

    @objc func restoreDefaults() {
        for action in ShortcutAction.allCases { rows[action]?.setShortcut(ShortcutConfiguration.defaults[action]) }
        draftChanged()
    }

    @objc private func dismiss() { close() }

    func windowWillClose(_ notification: Notification) {
        // Closing or Escape never commits an unfinished selection.
        update(configuration: savedConfiguration, warning: savedWarning)
    }

    private func draftChanged() {
        setFeedback(draftConfiguration == savedConfiguration ? savedWarning ?? "" : "Changes are not applied yet.",
                    isError: draftConfiguration == savedConfiguration && savedWarning != nil)
        updateActionState()
    }

    private func setFeedback(_ text: String, isError: Bool) {
        hasError = isError
        feedback.stringValue = text
        feedback.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func updateActionState() {
        let changed = draftConfiguration != savedConfiguration
        applyButton.isEnabled = changed || hasError
        doneButton.title = changed ? "Cancel" : "Done"
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let title = NoteStyle.label("Keyboard shortcuts", size: 24, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Choose Control, Option, or Command and a key. You can add Shift too.")
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, intro])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 8
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 22
        for action in ShortcutAction.allCases {
            if !form.arrangedSubviews.isEmpty {
                let divider = NSBox(); divider.boxType = .separator
                form.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
            }
            let row = ShortcutChoiceRow(action: action, shortcut: savedConfiguration[action])
            row.onChange = { [weak self] in self?.draftChanged() }
            rows[action] = row
            form.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        let limitation = NSTextField(wrappingLabelWithString: "Checks macOS shortcuts and conflicts reported by the system. Some app shortcuts can’t be detected.")
        limitation.font = .systemFont(ofSize: 12)
        limitation.textColor = .secondaryLabelColor
        feedback.font = .systemFont(ofSize: 12)
        feedback.setAccessibilityLabel("Shortcut status")
        feedback.setContentCompressionResistancePriority(.required, for: .vertical)
        let reset = NSButton(title: "Restore defaults", target: self, action: #selector(restoreDefaults))
        reset.isBordered = false
        reset.font = .systemFont(ofSize: 12)
        reset.contentTintColor = .secondaryLabelColor
        doneButton = NoteStyle.button("Done", target: self, action: #selector(dismiss))
        applyButton = NoteStyle.button("Apply", target: self, action: #selector(applyChanges))
        applyButton.bezelColor = NoteStyle.actionFill
        applyButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [reset, NSView(), doneButton, applyButton])
        footer.spacing = 10
        for view in [heading, form, limitation, feedback, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            intro.widthAnchor.constraint(equalTo: heading.widthAnchor),
            form.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 30),
            form.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            limitation.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 24),
            limitation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            limitation.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            feedback.topAnchor.constraint(equalTo: limitation.bottomAnchor, constant: 12),
            feedback.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            feedback.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }
}
