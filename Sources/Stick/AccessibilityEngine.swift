import AppKit
import ApplicationServices
import StickCore

/// All rectangles use Accessibility's top-left screen coordinate system.
struct DocumentContext {
    let appBundleID: String
    let appName: String
    let documentID: String
    let documentTitle: String
    let pid: pid_t
    let windowFrame: CGRect
}

struct CapturedAnchor {
    let context: DocumentContext
    let anchor: TextAnchor
    let bounds: CGRect
}

enum PinLocation {
    case visible(CGRect)
    case offscreen
    case missing
    case ambiguous
}

enum AccessibilityFailure: LocalizedError {
    case permission, noWindow, noSelection, unsupportedSelection, scanIncomplete, ambiguousSelection
    var errorDescription: String? {
        switch self {
        case .permission: return "Allow Stick in System Settings → Privacy & Security → Accessibility, then try again."
        case .noWindow: return "Open a document in another app first."
        case .noSelection: return "Select the text you want to pin, then press Add Note again."
        case .unsupportedSelection: return "This app does not expose a usable position for the selected text. Try a shorter selection or another app."
        case .scanIncomplete: return "This document took too long to inspect. Try again with the target text visible."
        case .ambiguousSelection: return "That text appears in several places. Select a longer, more distinctive passage."
        }
    }
}

/// Call from one serial worker queue. No clipboard, keyboard injection, or settings mutations.
final class AccessibilityEngine {
    private var deadline = Date.distantFuture
    private var exhausted = false

    private struct Session {
        let app: AXUIElement
        let window: AXUIElement
        let content: AXUIElement
        let context: DocumentContext
        let browser: Bool
    }
    private struct TextNode {
        let element: AXUIElement
        let text: String
        let clip: CGRect
        let ancestorText: Int?
    }
    private struct Located {
        let node: Int
        let range: NSRange
        let rect: CGRect?
    }

    func currentContext(pid: pid_t) throws -> DocumentContext {
        startScan()
        return try session(pid: pid).context
    }

    func captureSelection(pid: pid_t) throws -> CapturedAnchor {
        startScan()
        let session = try session(pid: pid)
        let focused = element(read(session.app, "AXFocusedUIElement"))
        // Browser selections belong to the document, never its address/search bar.
        var selectionElements = [AXUIElement]()
        if let focused, !session.browser || isDescendant(focused, of: session.content) {
            selectionElements.append(focused)
        }
        selectionElements.append(session.content)
        var quote: String?
        var selectionAnchor: TextAnchor?
        var selectionBounds: CGRect?
        for source in selectionElements {
            if let value = read(source, "AXValue") as? String,
               let selected = range(read(source, "AXSelectedTextRange")),
               selected.length > 0, selected.length <= 5000,
               selected.location >= 0, NSMaxRange(selected) <= (value as NSString).length {
                selectionAnchor = TextAnchor.capture(text: value, range: selected)
                quote = (value as NSString).substring(with: selected)
                selectionBounds = bounds(source, range: selected)
                break
            }
            if let markerRange = read(source, "AXSelectedTextMarkerRange"),
               let text = parameter(source, "AXStringForTextMarkerRange", markerRange) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (text as NSString).length <= 5000 {
                quote = text
                selectionBounds = rectangle(parameter(source, "AXBoundsForTextMarkerRange", markerRange))
                break
            }
        }
        let nodes = textNodes(session)
        // Some apps place selection attributes on a text descendant rather than the focused container.
        if quote == nil {
            for node in nodes {
                guard let selected = range(read(node.element, "AXSelectedTextRange")), selected.length > 0,
                      selected.length <= 5000, selected.location >= 0, NSMaxRange(selected) <= (node.text as NSString).length else { continue }
                selectionAnchor = TextAnchor.capture(text: node.text, range: selected)
                quote = (node.text as NSString).substring(with: selected)
                selectionBounds = bounds(node.element, range: selected)
                break
            }
        }
        guard let quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if exhausted { throw AccessibilityFailure.scanIncomplete }
            throw AccessibilityFailure.noSelection
        }
        var candidates = [Located]()
        for (index, node) in nodes.enumerated() {
            for match in occurrences(quote, in: node.text) {
                let rect = bounds(node.element, range: match)
                // Safari marker geometry identifies which repeated paragraph the user selected.
                if let selectedRect = selectionBounds, let rect,
                   !selectedRect.intersects(rect) { continue }
                candidates.append(Located(node: index, range: match, rect: rect))
            }
        }
        candidates = coalesce(candidates, nodes: nodes)
        if let selectionAnchor {
            candidates = candidates.filter { item in
                if case .found(let found) = AnchorMatcher.locate(selectionAnchor, in: nodes[item.node].text) {
                    return found == item.range
                }
                return false
            }
        }
        if exhausted { throw AccessibilityFailure.scanIncomplete }
        guard candidates.count == 1, let item = candidates.first else {
            if candidates.count > 1 { throw AccessibilityFailure.ambiguousSelection }
            throw AccessibilityFailure.unsupportedSelection
        }
        let node = nodes[item.node]
        guard let anchor = TextAnchor.capture(text: node.text, range: item.range),
              let rect = item.rect, !rect.intersection(node.clip).isEmpty else {
            throw AccessibilityFailure.unsupportedSelection
        }
        return CapturedAnchor(context: session.context, anchor: anchor, bounds: rect.intersection(node.clip))
    }

    func resolve(notes: [StickNote], pid: pid_t) throws -> (DocumentContext, [UUID: PinLocation]) {
        startScan()
        let session = try session(pid: pid)
        let relevant = notes.filter { $0.appBundleID == session.context.appBundleID && $0.documentID == session.context.documentID }
        guard !relevant.isEmpty else { return (session.context, [:]) }
        let nodes = textNodes(session)
        var results = [UUID: PinLocation]()
        for note in relevant {
            var candidates = [Located]()
            var hasAmbiguity = false
            for (index, node) in nodes.enumerated() {
                switch AnchorMatcher.locate(note.anchor, in: node.text) {
                case .found(let found): candidates.append(Located(node: index, range: found, rect: bounds(node.element, range: found)))
                case .ambiguous: hasAmbiguity = true
                case .missing: break
                }
            }
            candidates = coalesce(candidates, nodes: nodes)
            if hasAmbiguity || candidates.count > 1 { results[note.id] = .ambiguous }
            else if let candidate = candidates.first {
                if let rect = candidate.rect {
                    let clipped = rect.intersection(nodes[candidate.node].clip)
                    results[note.id] = clipped.isNull || clipped.isEmpty ? .offscreen : .visible(clipped)
                } else { results[note.id] = .offscreen }
            } else { results[note.id] = .missing }
        }
        if exhausted { throw AccessibilityFailure.scanIncomplete }
        return (session.context, results)
    }

    private func startScan() {
        deadline = Date().addingTimeInterval(1.3)
        exhausted = false
    }
    private func allowed() -> Bool {
        if Date() >= deadline { exhausted = true; return false }
        return true
    }
    private func session(pid: pid_t) throws -> Session {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permission }
        guard let running = NSRunningApplication(processIdentifier: pid), let bundleID = running.bundleIdentifier else { throw AccessibilityFailure.noWindow }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        guard let window = element(read(app, "AXFocusedWindow")) ?? element(read(app, "AXMainWindow")), let frame = frame(window) else {
            throw exhausted ? AccessibilityFailure.scanIncomplete : AccessibilityFailure.noWindow
        }
        let title = read(window, "AXTitle") as? String ?? running.localizedName ?? "Document"
        let file = urlString(read(window, "AXDocument"))
        // Native file-backed editors may themselves have a web area; their file URL takes priority.
        let web = file == nil ? firstWebArea(window) : nil
        let webURL = web.flatMap { urlString(read($0, "AXURL")) }
        let isBrowserPage = webURL.map { $0.hasPrefix("https:") || $0.hasPrefix("http:") || $0.hasPrefix("file:") } ?? false
        let documentID = file ?? (isBrowserPage ? webURL : nil) ?? "window-title:\(title)"
        let context = DocumentContext(appBundleID: bundleID, appName: running.localizedName ?? bundleID, documentID: documentID,
                                      documentTitle: title, pid: pid, windowFrame: frame)
        return Session(app: app, window: window, content: isBrowserPage ? web! : window, context: context, browser: isBrowserPage)
    }
    private func firstWebArea(_ root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 500, allowed() {
            let (node, depth) = queue[index]; index += 1
            if read(node, "AXRole") as? String == "AXWebArea" { return node }
            if depth < 12 { queue.append(contentsOf: children(node).map { ($0, depth + 1) }) }
        }
        return nil
    }
    private func textNodes(_ session: Session) -> [TextNode] {
        var output = [TextNode]()
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int, clip: CGRect, ancestor: Int?) {
            guard allowed(), depth <= 40, visited < 2200 else { exhausted = true; return }
            visited += 1
            let role = read(node, "AXRole") as? String ?? ""
            if ["AXToolbar", "AXMenuBar", "AXMenu", "AXTabGroup"].contains(role) && !CFEqual(node, session.content) {
                // Tab groups may contain a browser web area. The document root is already selected above.
                if role != "AXTabGroup" { return }
            }
            if read(node, "AXSubrole") as? String == "AXSecureTextField" { return }
            var nextClip = clip
            if role == "AXScrollArea", let scrollFrame = frame(node) { nextClip = clip.intersection(scrollFrame) }
            // Electron editors often expose the viewport as a group, while their
            // accessibility text buffer is only one line tall at the caret.
            if role == "AXGroup", let groupFrame = frame(node), groupFrame.width >= 80, groupFrame.height >= 80 {
                nextClip = nextClip.intersection(groupFrame)
            }
            var nextAncestor = ancestor
            if ["AXTextArea", "AXStaticText", "AXTextField"].contains(role),
               let text = read(node, "AXValue") as? String, !text.isEmpty, (text as NSString).length <= 2_000_000 {
                let ownFrame = frame(node)
                // Exclude offscreen live announcers, but retain ordinary offscreen document text.
                if role != "AXStaticText" || ownFrame.map({ $0.width > 1 && $0.height > 0 }) != false {
                    output.append(TextNode(element: node, text: text, clip: nextClip, ancestorText: ancestor))
                    nextAncestor = output.count - 1
                }
            }
            for child in children(node) { walk(child, depth: depth + 1, clip: nextClip, ancestor: nextAncestor) }
        }
        // Remove the title bar from eligibility when no scroll container is available.
        var contentClip = CGRect(x: session.context.windowFrame.minX, y: session.context.windowFrame.minY + 28,
                                 width: session.context.windowFrame.width, height: max(0, session.context.windowFrame.height - 28))
        // A browser scan starts inside AXWebArea, below its native scroll container.
        // Include those ancestors so scrolled text cannot leave pins on the toolbar.
        var parent = element(read(session.content, "AXParent"))
        for _ in 0..<24 {
            guard let current = parent, !CFEqual(current, session.window), allowed() else { break }
            if read(current, "AXRole") as? String == "AXScrollArea", let viewport = frame(current) {
                contentClip = contentClip.intersection(viewport)
            }
            parent = element(read(current, "AXParent"))
        }
        walk(session.content, depth: 0, clip: contentClip, ancestor: nil)
        return output
    }

    /// Eliminate duplicate representations of the same text in parent/child AX nodes only.
    /// Identical paragraphs in separate branches remain ambiguous.
    private func coalesce(_ candidates: [Located], nodes: [TextNode]) -> [Located] {
        var output = candidates
        for candidate in candidates {
            var ancestor = nodes[candidate.node].ancestorText
            while let index = ancestor {
                if let parent = output.first(where: { $0.node == index && $0.range == candidate.range && nodes[index].text == nodes[candidate.node].text }) {
                    if candidate.rect != nil || parent.rect == nil { output.removeAll { $0.node == index } }
                    else { output.removeAll { $0.node == candidate.node } }
                }
                ancestor = nodes[index].ancestorText
            }
        }
        return output
    }
    private func occurrences(_ quote: String, in text: String) -> [NSRange] {
        let source = text as NSString
        var result = [NSRange]()
        var offset = 0
        while offset < source.length, result.count < 32 {
            let found = source.range(of: quote, options: [], range: NSRange(location: offset, length: source.length - offset))
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found); offset = NSMaxRange(found)
        }
        return result
    }
    private func isDescendant(_ node: AXUIElement, of root: AXUIElement) -> Bool {
        var current: AXUIElement? = node
        for _ in 0..<40 {
            guard let value = current, allowed() else { return false }
            if CFEqual(value, root) { return true }
            current = element(read(value, "AXParent"))
        }
        return false
    }
    private func read(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard allowed() else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
        if result == .cannotComplete || result == .invalidUIElement || result == .failure { exhausted = true }
        return result == .success ? value : nil
    }
    private func parameter(_ node: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
        guard allowed() else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(node, name as CFString, input, &value)
        if result == .cannotComplete || result == .invalidUIElement || result == .failure { exhausted = true }
        return result == .success ? value : nil
    }
    private func children(_ node: AXUIElement) -> [AXUIElement] { read(node, "AXChildren") as? [AXUIElement] ?? [] }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func urlString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let value = value as? String, !value.isEmpty { return value }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL as URL).absoluteString }
        return nil
    }
    private func range(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var result = CFRange()
        guard AXValueGetValue(ax, .cfRange, &result), result.location >= 0, result.length >= 0,
              result.location < Int.max - result.length else { return nil }
        return NSRange(location: result.location, length: result.length)
    }
    private func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = read(node, "AXPosition"), let size = read(node, "AXSize"),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    private func rectangle(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        guard AXValueGetType(ax) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ax, .cgRect, &rect), !rect.isEmpty, !rect.isNull,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }
    private func bounds(_ node: AXUIElement, range: NSRange) -> CGRect? {
        // A pin marks the start of a passage. Large multiline union rectangles obscure its position.
        var small = CFRange(location: range.location, length: min(range.length, 1))
        guard let input = AXValueCreate(.cfRange, &small) else { return nil }
        return rectangle(parameter(node, "AXBoundsForRange", input))
    }
}
