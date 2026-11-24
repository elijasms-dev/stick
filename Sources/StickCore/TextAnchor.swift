import Foundation

/// A durable textual anchor. Offsets are UTF-16 offsets, matching macOS AX ranges.
public struct TextAnchor: Codable, Equatable, Sendable {
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var originalOffset: Int
    /// Persist an observed invalidation so reopening Stick cannot choose a survivor.
    public var requiresReattachment: Bool? = nil

    public init(quote: String, prefix: String, suffix: String, originalOffset: Int) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.originalOffset = originalOffset
    }

    /// The persisted invalidation flag must not break verified same-session undo.
    public func hasSameAttachment(as other: TextAnchor) -> Bool {
        quote == other.quote && prefix == other.prefix && suffix == other.suffix && originalOffset == other.originalOffset
    }

    public static func capture(text: String, range: NSRange) -> TextAnchor? {
        guard range.location != NSNotFound, range.length > 0,
              range.location >= 0, range.length >= 0,
              range.location <= (text as NSString).length,
              range.length <= (text as NSString).length - range.location,
              let stringRange = Range(range, in: text) else { return nil }
        let quote = String(text[stringRange])
        // Foundation can round a range inside a surrogate pair when slicing a
        // Swift String. Reject it rather than save a quote at an incorrect offset.
        guard quote.utf16.count == range.length,
              NSRange(stringRange, in: text) == range,
              !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TextAnchor(
            quote: quote,
            prefix: String(text[..<stringRange.lowerBound].suffix(64)),
            suffix: String(text[stringRange.upperBound...].prefix(64)),
            originalOffset: range.location
        )
    }
}

public enum AnchorMatch: Equatable, Sendable {
    case found(NSRange)
    case ambiguous
    case missing
}

public enum AnchorMatcher {
    /// Finds the original quote with its saved context, even if only one copy remains.
    /// The old offset is intentionally never used to break a tie.
    public static func locate(_ anchor: TextAnchor, in text: String) -> AnchorMatch {
        guard !anchor.quote.isEmpty, anchor.requiresReattachment != true else { return .missing }
        let source = text as NSString
        let quoteLength = (anchor.quote as NSString).length
        var searchStart = 0
        var match: NSRange?
        let hasContext = !anchor.prefix.isEmpty || !anchor.suffix.isEmpty
        let prefixLength = (anchor.prefix as NSString).length
        let suffixLength = (anchor.suffix as NSString).length
        while searchStart <= source.length - quoteLength {
            let searchRange = NSRange(location: searchStart, length: source.length - searchStart)
            let range = source.range(of: anchor.quote, options: .literal, range: searchRange)
            guard range.location != NSNotFound else { break }
            // Include overlapping occurrences rather than silently selecting one.
            searchStart = range.location + 1
            if hasContext {
                guard range.location >= prefixLength,
                      source.length - NSMaxRange(range) >= suffixLength else { continue }
                let before = source.substring(with: NSRange(location: range.location - prefixLength, length: prefixLength))
                let after = source.substring(with: NSRange(location: NSMaxRange(range), length: suffixLength))
                guard before == anchor.prefix && after == anchor.suffix else { continue }
            }
            if match != nil { return .ambiguous }
            match = range
        }
        return match.map(AnchorMatch.found) ?? .missing
    }
}
