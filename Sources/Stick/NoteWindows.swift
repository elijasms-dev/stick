import AppKit
import StickCore

enum NoteStyle {
    // Quiet, opaque surfaces stay legible over other apps. Resolve colors at draw time.
    static let accent = adaptive(light: 0x6255D9, dark: 0xB4AAFF)
    static let actionFill = adaptive(light: 0x6255D9, dark: 0x6B5CDC)
    static let paper = adaptive(light: 0xFFFFFF, dark: 0x22242B)
    static let surface = adaptive(light: 0xF7F8FC, dark: 0x30343F)
    static let edge = adaptive(light: 0xDDE1EA, dark: 0x555B6B)
    static let hover = adaptive(light: 0xEEEBFF, dark: 0x3D3758)
    static let pressed = adaptive(light: 0xDED8FF, dark: 0x4C426B)

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
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

final class NoteSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NoteStyle.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
    private let onChange: (StickNote) -> Bool
    private let onDelete: (UUID) -> Bool
    private let onClose: () -> Void
    private let textView = NoteTextView()
    private var reportedClose = false
    private var hasSavedFrame = false
    private var pendingSave: DispatchWorkItem?
    private var hasUnsavedChanges = false
    private let saveStatus = NoteStyle.label("Saved on this Mac", size: 11, color: .secondaryLabelColor)

    init(note: StickNote, onChange: @escaping (StickNote) -> Bool,
         onDelete: @escaping (UUID) -> Bool, onClose: @escaping () -> Void) {
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
        window.backgroundColor = NoteStyle.paper
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
        let source = NoteStyle.label(note.documentTitle, size: 14, weight: .semibold)
        source.toolTip = note.documentTitle
        source.setAccessibilityLabel("Source document")
        let app = NoteStyle.label(note.appName, color: .secondaryLabelColor)
        let quote = NoteStyle.label(note.anchor.quote.replacingOccurrences(of: "\n", with: " "), size: 12)
        quote.toolTip = note.anchor.quote
        quote.setAccessibilityLabel("Pinned text")
        let quoteIcon = NSImageView(image: NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)!)
        quoteIcon.contentTintColor = NoteStyle.accent
        quoteIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        quoteIcon.setAccessibilityElement(false)
        quoteIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let quoteRow = NSStackView(views: [quoteIcon, quote])
        quoteRow.orientation = .horizontal
        quoteRow.spacing = 8
        quoteRow.alignment = .centerY
        let quoteSurface = NoteSurface()
        quoteRow.translatesAutoresizingMaskIntoConstraints = false
        quoteSurface.addSubview(quoteRow)
        NSLayoutConstraint.activate([
            quoteRow.leadingAnchor.constraint(equalTo: quoteSurface.leadingAnchor, constant: 10),
            quoteRow.trailingAnchor.constraint(equalTo: quoteSurface.trailingAnchor, constant: -10),
            quoteRow.topAnchor.constraint(equalTo: quoteSurface.topAnchor, constant: 9),
            quoteRow.bottomAnchor.constraint(equalTo: quoteSurface.bottomAnchor, constant: -9)
        ])

        textView.string = note.body
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .textColor
        textView.backgroundColor = NoteStyle.paper
        textView.insertionPointColor = NoteStyle.accent
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 12)
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
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        saveStatus.setAccessibilityLabel("Save status")
        let delete = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete this note")!,
                              target: self, action: #selector(deleteNote))
        delete.isBordered = false
        delete.contentTintColor = .secondaryLabelColor
        delete.toolTip = "Delete this note"
        delete.widthAnchor.constraint(equalToConstant: 28).isActive = true
        delete.heightAnchor.constraint(equalToConstant: 28).isActive = true
        delete.setAccessibilityLabel("Delete this note")
        let done = NoteStyle.button("Done", target: self, action: #selector(doneEditing))
        done.bezelColor = NoteStyle.actionFill
        done.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        let footer = NSStackView(views: [saveStatus, spacer, delete, done])
        footer.orientation = .horizontal
        footer.spacing = 8
        let header = NSStackView(views: [source, app, quoteSurface])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.setCustomSpacing(12, after: app)
        let divider = NSBox()
        divider.boxType = .separator
        for view in [header, scroll, divider, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            source.widthAnchor.constraint(equalTo: header.widthAnchor),
            app.widthAnchor.constraint(equalTo: header.widthAnchor),
            quoteSurface.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
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
        guard note.body != textView.string else { return }
        note.body = textView.string
        note.updatedAt = Date()
        hasUnsavedChanges = true
        saveStatus.stringValue = "Saving…"
        saveStatus.textColor = .secondaryLabelColor
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushChanges() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Close, replacement, and app termination flush edits immediately.
    @discardableResult func flushChanges() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasUnsavedChanges else { return true }
        let saved = onChange(note)
        hasUnsavedChanges = !saved
        saveStatus.stringValue = saved ? "Saved on this Mac" : "Not saved — keep this note open"
        saveStatus.textColor = saved ? .secondaryLabelColor : .systemRed
        return saved
    }

    override func close() {
        guard flushChanges() else { return }
        super.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { flushChanges() }

    func discardAndClose() {
        pendingSave?.cancel()
        pendingSave = nil
        hasUnsavedChanges = false
        close()
    }

    @objc private func doneEditing() { close() }
    @objc private func deleteNote() {
        guard let window else { return }
        NoteStyle.confirmDeletion(in: window) { [weak self] in
            guard let self, self.onDelete(self.note.id) else { return }
            self.discardAndClose()
        }
    }
    func windowWillClose(_ notification: Notification) {
        guard !reportedClose else { return }
        reportedClose = true
        onClose()
    }
}

private final class NotesTableView: NSTableView {
    var onOpen: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onOpen?() }
        else { super.keyDown(with: event) }
    }
}

private final class NoteCell: NSTableCellView {
    let titleLabel = NoteStyle.label("", size: 14, weight: .medium)
    let sourceLabel = NoteStyle.label("", size: 11, color: .secondaryLabelColor)
    let quoteLabel = NoteStyle.label("", size: 12, color: .secondaryLabelColor)
    let locationLabel = NoteStyle.label("Needs location", size: 10, weight: .medium, color: NoteStyle.accent)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let titleRow = NSStackView(views: [titleLabel, locationLabel])
        titleRow.spacing = 12
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [titleRow, sourceLabel, quoteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
    private let table = NotesTableView()
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let countLabel = NoteStyle.label("Your notes stay on this Mac", size: 12, color: .secondaryLabelColor)
    private let filter = NSSegmentedControl(labels: ["All notes", "Needs location"], trackingMode: .selectOne, target: nil, action: nil)
    private let emptyTitle = NoteStyle.label("", size: 17, weight: .medium)
    private let emptyLabel = NoteStyle.label("", size: 13, color: .secondaryLabelColor)
    private let emptyState = NSStackView()
    private var actionButtons: [NSButton] = []
    private var hasSavedFrame = false
    private var needsReload = false
    private var renderedUnplaced = Set<UUID>()
    private var addNoteShortcut: KeyboardShortcut

    init(onOpen: @escaping (UUID) -> Void, onReveal: @escaping (UUID) -> Void,
         onReattach: @escaping (UUID) -> Void, onDelete: @escaping (UUID) -> Void,
         addNoteShortcut: KeyboardShortcut = ShortcutConfiguration.defaults.addNote) {
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onReattach = onReattach
        self.onDelete = onDelete
        self.addNoteShortcut = addNoteShortcut
        let window = EscapeWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Stick — All notes"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 380)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NoteStyle.paper
        super.init(window: window)
        hasSavedFrame = window.setFrameUsingName("StickAllNotes")
        window.setFrameAutosaveName("StickAllNotes")
        window.onEscape = { [weak self] in self?.close() }
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let title = NoteStyle.label("Your notes", size: 24, weight: .semibold)
        let heading = NSStackView(views: [title, countLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 5
        search.placeholderString = "Search notes or places"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.controlSize = .large
        search.setAccessibilityLabel("Search notes")
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("Filter notes")
        let controls = NSStackView(views: [search, filter])
        controls.orientation = .horizontal
        controls.spacing = 12
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 84
        table.style = .inset
        table.backgroundColor = NoteStyle.paper
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onOpen = { [weak self] in self?.openSelected() }
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Saved notes")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
        let open = NoteStyle.button("Edit note", target: self, action: #selector(openSelected))
        open.bezelColor = NoteStyle.actionFill
        let reveal = NoteStyle.button("Open source", target: self, action: #selector(revealSelected))
        let reattach = NoteStyle.button("Reattach…", target: self, action: #selector(reattachSelected))
        let delete = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete selected note")!, target: self, action: #selector(deleteSelected))
        delete.isBordered = false
        delete.toolTip = "Delete selected note"
        delete.contentTintColor = .secondaryLabelColor
        delete.widthAnchor.constraint(equalToConstant: 28).isActive = true
        actionButtons = [open, reveal, reattach, delete]
        let footer = NSStackView(views: [open, reveal, reattach, NSView(), delete])
        footer.orientation = .horizontal
        footer.spacing = 8
        emptyLabel.maximumNumberOfLines = 3
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10
        let emptyIcon = NSImageView(image: StickBrand.image(size: 36))
        emptyIcon.setAccessibilityElement(false)
        for view in [emptyIcon, emptyTitle, emptyLabel] { emptyState.addArrangedSubview(view) }
        let divider = NSBox(); divider.boxType = .separator
        for view in [heading, controls, scroll, divider, footer, emptyState] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            controls.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 22),
            controls.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),
            divider.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -72),
            emptyLabel.widthAnchor.constraint(equalTo: emptyState.widthAnchor)
        ])
        reload()
    }

    func update(notes: [StickNote], unplaced: Set<UUID>) {
        guard notes != self.notes || unplaced != self.unplaced else { return }
        self.notes = notes
        self.unplaced = unplaced
        // Editing a note should not rebuild an invisible list on every save.
        needsReload = true
        if window?.isVisible == true { reload() }
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        guard shortcut != addNoteShortcut else { return }
        addNoteShortcut = shortcut
        needsReload = true
        if window?.isVisible == true { reload() }
    }

    func present() {
        if needsReload { reload() }
        NSApp.activate(ignoringOtherApps: true)
        if !hasSavedFrame { window?.center(); hasSavedFrame = true }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    private var selected: StickNote? {
        filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil
    }

    private func reload(resetScroll: Bool = false) {
        needsReload = false
        let previous = selected?.id
        let oldNotes = filtered
        let scrollOrigin = scroll.contentView.bounds.origin
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = notes.filter { note in
            (filter.selectedSegment != 1 || unplaced.contains(note.id)) &&
            (query.isEmpty || [note.body, note.documentTitle, note.appName, note.anchor.quote]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        if oldNotes.map(\.id) == filtered.map(\.id) {
            // Refresh changed rows only; leave selection, scroll position and focus alone.
            let changed = IndexSet(filtered.indices.filter { index in
                oldNotes[index] != filtered[index] || renderedUnplaced.contains(filtered[index].id) != unplaced.contains(filtered[index].id)
            })
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        } else {
            table.reloadData()
            table.deselectAll(nil)
            if let previous, let row = filtered.firstIndex(where: { $0.id == previous }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        renderedUnplaced = unplaced
        if resetScroll { scroll.contentView.scroll(to: .zero) }
        else { scroll.contentView.scroll(to: scrollOrigin) }
        scroll.reflectScrolledClipView(scroll.contentView)
        countLabel.stringValue = query.isEmpty && filter.selectedSegment == 0
            ? "\(notes.count) \(notes.count == 1 ? "note" : "notes") saved on this Mac"
            : "\(filtered.count) of \(notes.count) notes"
        emptyState.isHidden = !filtered.isEmpty
        emptyTitle.stringValue = !query.isEmpty ? "No matching notes" : filter.selectedSegment == 1
            ? "No locations to fix" : "Leave a note where you are"
        emptyLabel.stringValue = !query.isEmpty ? "Try a word from your note, selected text, document, or app." : filter.selectedSegment == 1
            ? "No missing locations found in the documents Stick has checked."
            : "Select text in another app, then press \(addNoteShortcut.spokenString). Your notes will appear here."
        setActionState()
    }

    private func setActionState() { actionButtons.forEach { $0.isEnabled = selected != nil } }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("NoteCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NoteCell) ?? NoteCell()
        cell.identifier = id
        let note = filtered[row]
        cell.titleLabel.stringValue = note.body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "Untitled note"
        cell.sourceLabel.stringValue = "\(note.documentTitle) in \(note.appName)"
        cell.quoteLabel.stringValue = "“" + note.anchor.quote.replacingOccurrences(of: "\n", with: " ") + "”"
        cell.locationLabel.isHidden = !unplaced.contains(note.id)
        cell.toolTip = note.body
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { setActionState() }
    func controlTextDidChange(_ obj: Notification) { reload(resetScroll: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if selected == nil && !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            openSelected()
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)), !filtered.isEmpty {
            if selected == nil { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            window?.makeFirstResponder(table)
            return true
        }
        return false
    }
    @objc private func filterChanged() { reload(resetScroll: true) }
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
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    func refreshHoverState() {
        guard let window else { return }
        let hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        if hovered != isHovered { isHovered = hovered; needsDisplay = true }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let isPressed = cell?.isHighlighted == true
        let tab = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.5, dy: 2.5), xRadius: 6, yRadius: 6)
        (isPressed ? NoteStyle.pressed : isHovered ? NoteStyle.hover : NoteStyle.surface).setFill()
        tab.fill()
        (isHovered || isPressed ? NoteStyle.accent : NoteStyle.edge).setStroke()
        tab.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.5 : 1
        tab.stroke()

        // A folded note, rather than a literal pushpin. All states share the same hit target.
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX - 13, yBy: bounds.midY - 13 + (isPressed ? 0.5 : 0))
        transform.concat()
        let note = NSBezierPath()
        note.move(to: NSPoint(x: 9, y: 6.5))
        note.line(to: NSPoint(x: 17, y: 6.5))
        note.curve(to: NSPoint(x: 18.5, y: 8), controlPoint1: NSPoint(x: 18, y: 6.5), controlPoint2: NSPoint(x: 18.5, y: 7))
        note.line(to: NSPoint(x: 18.5, y: 15))
        note.line(to: NSPoint(x: 14, y: 19.5))
        note.line(to: NSPoint(x: 9, y: 19.5))
        note.curve(to: NSPoint(x: 7.5, y: 18), controlPoint1: NSPoint(x: 8, y: 19.5), controlPoint2: NSPoint(x: 7.5, y: 19))
        note.line(to: NSPoint(x: 7.5, y: 8))
        note.curve(to: NSPoint(x: 9, y: 6.5), controlPoint1: NSPoint(x: 7.5, y: 7), controlPoint2: NSPoint(x: 8, y: 6.5))
        note.close()
        NoteStyle.accent.setFill()
        note.fill()

        let marks = NSBezierPath()
        marks.move(to: NSPoint(x: 10, y: 10))
        marks.line(to: NSPoint(x: 16, y: 10))
        marks.move(to: NSPoint(x: 10, y: 13))
        marks.line(to: NSPoint(x: 13, y: 13))
        marks.move(to: NSPoint(x: 14, y: 19))
        marks.line(to: NSPoint(x: 14, y: 15))
        marks.line(to: NSPoint(x: 18, y: 15))
        marks.lineWidth = 1.2
        marks.lineCapStyle = .round
        marks.lineJoinStyle = .round
        NoteStyle.surface.setStroke()
        marks.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    @objc private func pressed() { onClick?() }
}

/// Layout is independent of windows so collision handling cannot move a pin to another line.
enum PinLayout {
    static let size: CGFloat = 26
    static let spacing: CGFloat = 29

    static func frames(pins: [(id: UUID, rect: CGRect)], screens: [CGRect]) -> [UUID: CGRect] {
        var occupied: [CGRect] = []
        var frames: [UUID: CGRect] = [:]
        // Body edits and note-store ordering must not reshuffle pins on the same line.
        let ordered = pins.sorted { lhs, rhs in
            if lhs.rect.midY != rhs.rect.midY { return lhs.rect.midY > rhs.rect.midY }
            if lhs.rect.minX != rhs.rect.minX { return lhs.rect.minX < rhs.rect.minX }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for pin in ordered {
            guard let screen = screens.first(where: { $0.intersects(pin.rect) }),
                  pin.rect.isFinite, pin.rect.height > 0 else { continue }
            let y = pin.rect.midY - size / 2
            // Near a screen edge, hide rather than slide away from the source line.
            guard y >= screen.minY, y + size <= screen.maxY else { continue }
            let minX = screen.minX + 2
            let maxX = screen.maxX - size - 2
            guard maxX >= minX else { continue }
            let preferredX = max(minX, min(pin.rect.minX - size - 6, maxX))
            let slotCount = min(256, max(1, Int((maxX - minX) / spacing) + 1))
            var candidates = [preferredX]
            // First expand into the left margin; use the right only when it is full.
            for step in 1...slotCount {
                let left = preferredX - CGFloat(step) * spacing
                let right = preferredX + CGFloat(step) * spacing
                if left >= minX { candidates.append(left) }
                if right <= maxX { candidates.append(right) }
            }
            guard let frame = candidates.lazy.map({ CGRect(x: $0, y: y, width: size, height: size) })
                .first(where: { candidate in !occupied.contains { $0.insetBy(dx: -1, dy: -1).intersects(candidate) } }) else { continue }
            frames[pin.id] = frame
            occupied.append(frame)
        }
        return frames
    }
}

private extension CGRect {
    var isFinite: Bool { origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite }
}

@MainActor
final class PinOverlayController {
    private var panels: [UUID: PinPanel] = [:]

    func show(pins: [(id: UUID, rect: CGRect, label: String)], onClick: @escaping (UUID) -> Void) {
        let frames = PinLayout.frames(pins: pins.map { ($0.id, $0.rect) }, screens: NSScreen.screens.map(\.visibleFrame))
        let ids = Set(pins.map(\.id))
        for id in Array(panels.keys) where !ids.contains(id) {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        for pin in pins {
            guard let frame = frames[pin.id] else {
                panels[pin.id]?.orderOut(nil)
                continue
            }
            let panel: PinPanel
            let button: PinButton
            if let existing = panels[pin.id], let existingButton = existing.contentView as? PinButton {
                panel = existing
                button = existingButton
            } else {
                panel = PinPanel(contentRect: NSRect(x: 0, y: 0, width: PinLayout.size, height: PinLayout.size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.animationBehavior = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.isReleasedWhenClosed = false
                button = PinButton(frame: NSRect(origin: .zero, size: frame.size))
                panel.contentView = button
                panels[pin.id] = panel
            }
            button.onClick = { onClick(pin.id) }
            if button.toolTip != pin.label {
                button.toolTip = pin.label
                button.setAccessibilityLabel("Open note: \(pin.label)")
            }
            // A tracking update must not replay appearance or raise every window.
            // Position changes are immediate, keeping the marker on its text line.
            if panel.frame.origin != frame.origin { panel.setFrameOrigin(frame.origin) }
            if !panel.isVisible { panel.orderFrontRegardless() }
            button.refreshHoverState()
        }
    }

    func hide() {
        panels.values.filter(\.isVisible).forEach { $0.orderOut(nil) }
    }
}
