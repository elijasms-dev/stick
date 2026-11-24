import AppKit
import StickCore

private enum NoteStyle {
    static let accent = NSColor.systemYellow
    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }
    @MainActor
    static func confirmDeletion(in window: NSWindow, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Delete this note?"
        alert.informativeText = "The note and its pin will be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { completion() }
        }
    }
}

private final class EscapeWindow: NSWindow {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private final class NoteTextView: NSTextView {
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class NoteEditorController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {
    private var note: StickNote
    var noteID: UUID { note.id }
    private let onChange: (StickNote) -> Void
    private let onDelete: (UUID) -> Void
    private let onClose: () -> Void
    private let textView = NoteTextView()
    private var reportedClose = false
    private var hasSavedFrame = false

    init(note: StickNote, onChange: @escaping (StickNote) -> Void,
         onDelete: @escaping (UUID) -> Void, onClose: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        self.onDelete = onDelete
        self.onClose = onClose
        let window = EscapeWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Stick note"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 300, height: 260)
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        super.init(window: window)
        let frameName = NSWindow.FrameAutosaveName("StickNote-\(note.id.uuidString)")
        hasSavedFrame = window.setFrameUsingName(frameName)
        window.setFrameAutosaveName(frameName)
        window.delegate = self
        window.onEscape = { [weak self] in self?.close() }
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let source = NoteStyle.label(note.documentTitle, size: 13, weight: .semibold)
        source.toolTip = note.documentTitle
        source.setAccessibilityLabel("Source document")
        let app = NoteStyle.label(note.appName, color: .secondaryLabelColor)
        let quote = NoteStyle.label(note.anchor.quote.replacingOccurrences(of: "\n", with: " "), color: .secondaryLabelColor)
        quote.toolTip = note.anchor.quote
        quote.setAccessibilityLabel("Pinned text")
        let stripe = NSView()
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = NoteStyle.accent.cgColor
        stripe.widthAnchor.constraint(equalToConstant: 3).isActive = true
        let quoteRow = NSStackView(views: [stripe, quote])
        quoteRow.orientation = .horizontal
        quoteRow.spacing = 9
        quoteRow.alignment = .centerY
        stripe.heightAnchor.constraint(equalTo: quoteRow.heightAnchor).isActive = true

        textView.string = note.body
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.setAccessibilityLabel("Note text")
        textView.onEscape = { [weak self] in self?.close() }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let saved = NoteStyle.label("Saves as you type", color: .secondaryLabelColor)
        let delete = NoteStyle.button("Delete", target: self, action: #selector(deleteNote))
        delete.setAccessibilityLabel("Delete this note")
        let done = NoteStyle.button("Done", target: self, action: #selector(doneEditing))
        done.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let footer = NSStackView(views: [saved, spacer, delete, done])
        footer.orientation = .horizontal
        footer.spacing = 8
        let header = NSStackView(views: [source, app, quoteRow])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 5
        for view in [header, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            quoteRow.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    func present(near screenPoint: NSPoint?) {
        guard let window else { return }
        reportedClose = false
        if !hasSavedFrame, let point = screenPoint {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
            let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            var origin = NSPoint(x: point.x + 20, y: point.y - window.frame.height + 20)
            origin.x = max(available.minX, min(origin.x, available.maxX - window.frame.width))
            origin.y = max(available.minY, min(origin.y, available.maxY - window.frame.height))
            window.setFrameOrigin(origin)
        } else if !hasSavedFrame { window.center() }
        hasSavedFrame = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        note.body = textView.string
        note.updatedAt = Date()
        onChange(note)
    }

    @objc private func doneEditing() { close() }
    @objc private func deleteNote() {
        guard let window else { return }
        NoteStyle.confirmDeletion(in: window) { [weak self] in
            guard let self else { return }
            self.onDelete(self.note.id)
            self.close()
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard !reportedClose else { return }
        reportedClose = true
        onClose()
    }
}

private final class NoteCell: NSTableCellView {
    let titleLabel = NoteStyle.label("", size: 13, weight: .medium)
    let sourceLabel = NoteStyle.label("", size: 11, color: .secondaryLabelColor)
    let quoteLabel = NoteStyle.label("", size: 11, color: .secondaryLabelColor)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [titleLabel, sourceLabel, quoteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            quoteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class NotesListController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let onOpen: (UUID) -> Void
    private let onReveal: (UUID) -> Void
    private let onReattach: (UUID) -> Void
    private let onDelete: (UUID) -> Void
    private var notes: [StickNote] = []
    private var filtered: [StickNote] = []
    private var unplaced: Set<UUID> = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["All notes", "Unplaced"], trackingMode: .selectOne, target: nil, action: nil)
    private let emptyLabel = NoteStyle.label("", size: 13, color: .secondaryLabelColor)
    private var actionButtons: [NSButton] = []
    private var hasSavedFrame = false

    init(onOpen: @escaping (UUID) -> Void, onReveal: @escaping (UUID) -> Void,
         onReattach: @escaping (UUID) -> Void, onDelete: @escaping (UUID) -> Void) {
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onReattach = onReattach
        self.onDelete = onDelete
        let window = EscapeWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Stick — All notes"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 490, height: 320)
        super.init(window: window)
        hasSavedFrame = window.setFrameUsingName("StickAllNotes")
        window.setFrameAutosaveName("StickAllNotes")
        window.onEscape = { [weak self] in self?.close() }
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search notes, documents, or apps"
        search.delegate = self
        search.setAccessibilityLabel("Search notes")
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        let header = NSStackView(views: [search, filter])
        header.orientation = .horizontal
        header.spacing = 12
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 78
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Saved notes")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        let open = NoteStyle.button("Edit note", target: self, action: #selector(openSelected))
        let reveal = NoteStyle.button("Open source", target: self, action: #selector(revealSelected))
        let reattach = NoteStyle.button("Reattach…", target: self, action: #selector(reattachSelected))
        let delete = NoteStyle.button("Delete", target: self, action: #selector(deleteSelected))
        actionButtons = [open, reveal, reattach, delete]
        let footer = NSStackView(views: [open, reveal, reattach, NSView(), delete])
        footer.orientation = .horizontal
        footer.spacing = 8
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        for view in [header, scroll, footer, emptyLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60)
        ])
        reload()
    }

    func update(notes: [StickNote], unplaced: Set<UUID>) {
        guard notes != self.notes || unplaced != self.unplaced else { return }
        self.notes = notes
        self.unplaced = unplaced
        reload()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if !hasSavedFrame { window?.center(); hasSavedFrame = true }
        window?.makeKeyAndOrderFront(nil)
    }

    private var selected: StickNote? {
        filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil
    }

    private func reload() {
        let previous = selected?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = notes.filter { note in
            (filter.selectedSegment != 1 || unplaced.contains(note.id)) &&
            (query.isEmpty || [note.body, note.documentTitle, note.appName, note.anchor.quote]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.updatedAt > $1.updatedAt }
        table.reloadData()
        if let previous, let row = filtered.firstIndex(where: { $0.id == previous }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        emptyLabel.isHidden = !filtered.isEmpty
        emptyLabel.stringValue = !query.isEmpty ? "No matching notes." : filter.selectedSegment == 1
            ? "No notes currently need reattaching."
            : "Select some text in another app, then choose Add Note from the Stick menu."
        setActionState()
    }

    private func setActionState() { actionButtons.forEach { $0.isEnabled = selected != nil } }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("NoteCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NoteCell) ?? NoteCell()
        cell.identifier = id
        let note = filtered[row]
        let firstLine = note.body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "Empty note"
        cell.titleLabel.stringValue = firstLine
        cell.sourceLabel.stringValue = "\(note.appName) · \(note.documentTitle)" + (unplaced.contains(note.id) ? " · Location missing" : "")
        cell.quoteLabel.stringValue = note.anchor.quote.replacingOccurrences(of: "\n", with: " ")
        cell.toolTip = note.body
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { setActionState() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func filterChanged() { reload() }
    @objc private func openSelected() { if let note = selected { onOpen(note.id) } }
    @objc private func revealSelected() { if let note = selected { onReveal(note.id) } }
    @objc private func reattachSelected() { if let note = selected { onReattach(note.id) } }
    @objc private func deleteSelected() {
        guard let note = selected, let window else { return }
        NoteStyle.confirmDeletion(in: window) { [weak self] in self?.onDelete(note.id) }
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PinButton: NSButton {
    var onClick: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .circular
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.backgroundColor = NSColor.systemYellow.cgColor
        contentTintColor = .black
        image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Note pin")
        imagePosition = .imageOnly
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { onClick?() }
}

@MainActor
final class PinOverlayController {
    private var panels: [UUID: PinPanel] = [:]

    func show(pins: [(id: UUID, rect: CGRect, label: String)], onClick: @escaping (UUID) -> Void) {
        let ids = Set(pins.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        var occupied: [NSRect] = []
        for pin in pins {
            let panel: PinPanel
            let button: PinButton
            if let existing = panels[pin.id], let existingButton = existing.contentView as? PinButton {
                panel = existing
                button = existingButton
            } else {
                panel = PinPanel(contentRect: NSRect(x: 0, y: 0, width: 26, height: 26),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.isReleasedWhenClosed = false
                button = PinButton(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
                panel.contentView = button
                panels[pin.id] = panel
            }
            button.onClick = { onClick(pin.id) }
            button.toolTip = pin.label
            button.setAccessibilityLabel("Open note: \(pin.label)")
            var frame = NSRect(x: pin.rect.minX - 32, y: pin.rect.midY - 13, width: 26, height: 26)
            let screen = NSScreen.screens.first { $0.frame.intersects(pin.rect) } ?? NSScreen.main
            if let available = screen?.visibleFrame {
                frame.origin.x = max(available.minX + 2, min(frame.minX, available.maxX - 28))
                frame.origin.y = max(available.minY + 2, min(frame.minY, available.maxY - 28))
                let initialFrame = frame
                let columns = max(1, Int((available.width - 4) / 29))
                let rows = max(1, Int((available.height - 4) / 29))
                var attempts = 0
                while occupied.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(frame) }) && attempts < min(columns * rows, 256) {
                    attempts += 1
                    let horizontal = CGFloat(attempts % columns) * 29
                    let vertical = CGFloat(attempts / columns) * 29
                    let usableWidth = max(1, available.width - 30)
                    let usableHeight = max(1, available.height - 30)
                    frame.origin.x = available.minX + 2 + (initialFrame.minX - available.minX - 2 + horizontal).truncatingRemainder(dividingBy: usableWidth)
                    frame.origin.y = available.minY + 2 + (initialFrame.minY - available.minY - 2 + vertical).truncatingRemainder(dividingBy: usableHeight)
                }
            }
            occupied.append(frame)
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panels.values.forEach { $0.orderOut(nil) }
    }
}
