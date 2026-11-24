import Foundation

/// Translates a previously verified range through an observed edit in the same
/// text element. This is live edit continuity, not a search by approximate offset.
public struct TextEditTracker {
    fileprivate let previous: String
    fileprivate let current: String
    private let change: (start: Int, oldEnd: Int, newEnd: Int)?

    /// Compute the changed span once, then reuse it for all pins in this element.
    public init(from previous: String, to current: String) {
        self.previous = previous
        self.current = current
        guard previous != current else { change = nil; return }
        let oldUnits = Array(previous.utf16)
        let newUnits = Array(current.utf16)
        var start = 0
        while start < min(oldUnits.count, newUnits.count), oldUnits[start] == newUnits[start] { start += 1 }
        var oldEnd = oldUnits.count
        var newEnd = newUnits.count
        while oldEnd > start, newEnd > start, oldUnits[oldEnd - 1] == newUnits[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        change = (start, oldEnd, newEnd)
    }

    public static func relocate(quote: String, range: NSRange, from previous: String, to current: String) -> NSRange? {
        TextEditTracker(from: previous, to: current).relocate(quote: quote, range: range)
    }

    public func relocate(quote: String, range: NSRange) -> NSRange? {
        let old = previous as NSString
        let new = current as NSString
        guard !quote.isEmpty, range.location != NSNotFound, range.location >= 0,
              range.length == (quote as NSString).length,
              range.location <= old.length, range.length <= old.length - range.location,
              old.substring(with: range) == quote else { return nil }
        guard let change else { return range }

        let shifted: NSRange
        if change.oldEnd <= range.location {
            shifted = NSRange(location: range.location + change.newEnd - change.oldEnd, length: range.length)
        } else if change.start >= NSMaxRange(range) {
            shifted = range
        } else {
            // The edited span touches the quote. Multiple independent edits that
            // enclose it are intentionally treated the same way; their history
            // cannot be inferred safely from just these two snapshots.
            return nil
        }
        guard shifted.location >= 0, shifted.location <= new.length,
              shifted.length <= new.length - shifted.location,
              new.substring(with: shifted) == quote,
              Range(shifted, in: current) != nil else { return nil }

        // Deleting the first of two identical passages can look exactly like
        // deleting the second. Inserting a duplicate has the same ambiguity.
        // Do not let common-prefix alignment silently transfer a pin.
        guard Self.occurrenceCount(quote, in: old) == Self.occurrenceCount(quote, in: new) else { return nil }
        return shifted
    }

    private static func occurrenceCount(_ quote: String, in text: NSString) -> Int {
        var count = 0
        var offset = 0
        let length = (quote as NSString).length
        while offset <= text.length - length {
            let found = text.range(of: quote, options: .literal, range: NSRange(location: offset, length: text.length - offset))
            guard found.location != NSNotFound else { break }
            count += 1
            offset = found.location + 1
        }
        return count
    }
}

/// Remembers when observed edits invalidate a known pin. Once that happens, a
/// later search must not silently attach the pin to an identical surviving copy.
public struct LiveAnchorTracker {
    public private(set) var text: String
    public private(set) var range: NSRange
    public private(set) var anchor: TextAnchor
    public private(set) var isInvalidated = false

    public init?(anchor: TextAnchor, text: String, range: NSRange) {
        guard let captured = TextAnchor.capture(text: text, range: range), captured.quote == anchor.quote else { return nil }
        self.text = text
        self.range = range
        self.anchor = captured
    }

    public mutating func apply(_ edit: TextEditTracker) -> NSRange? {
        guard edit.previous == text else { return nil }
        if isInvalidated {
            // An exact undo restores the known snapshot and its original range.
            // Other edits require the user to choose a new attachment explicitly.
            guard edit.current == text else { return nil }
            isInvalidated = false
            return range
        }
        guard let shifted = edit.relocate(quote: anchor.quote, range: range),
              let refreshed = TextAnchor.capture(text: edit.current, range: shifted) else {
            isInvalidated = true
            return nil
        }
        text = edit.current
        range = shifted
        anchor = refreshed
        return shifted
    }
}
