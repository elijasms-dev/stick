import AppKit

/// One small folded-note mark shared by the app, menu bar, and onboarding.
enum StickBrand {
    private static let ink = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.706, green: 0.667, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.384, green: 0.333, blue: 0.851, alpha: 1)
    }
    static func image(size: CGFloat, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawMark(in: rect.insetBy(dx: size * 0.1, dy: size * 0.1),
                     color: template ? .black : ink)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Stick"
        return image
    }

    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let tile = rect.insetBy(dx: size * 0.07, dy: size * 0.07)
            NSColor(srgbRed: 0.384, green: 0.333, blue: 0.851, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: size * 0.19, yRadius: size * 0.19).fill()
            drawMark(in: rect.insetBy(dx: size * 0.25, dy: size * 0.23), color: .white)
            return true
        }
    }

    private static func drawMark(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 24, yBy: rect.height / 24)
        transform.concat()
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: 5, y: 2))
        outline.line(to: NSPoint(x: 19, y: 2))
        outline.curve(to: NSPoint(x: 22, y: 5), controlPoint1: NSPoint(x: 21, y: 2), controlPoint2: NSPoint(x: 22, y: 3))
        outline.line(to: NSPoint(x: 22, y: 15))
        outline.line(to: NSPoint(x: 15, y: 22))
        outline.line(to: NSPoint(x: 5, y: 22))
        outline.curve(to: NSPoint(x: 2, y: 19), controlPoint1: NSPoint(x: 3, y: 22), controlPoint2: NSPoint(x: 2, y: 21))
        outline.line(to: NSPoint(x: 2, y: 5))
        outline.curve(to: NSPoint(x: 5, y: 2), controlPoint1: NSPoint(x: 2, y: 3), controlPoint2: NSPoint(x: 3, y: 2))
        outline.close()
        outline.lineWidth = 1.8
        outline.lineJoinStyle = .round
        color.setStroke()
        outline.stroke()
        let details = NSBezierPath()
        details.move(to: NSPoint(x: 15, y: 21))
        details.line(to: NSPoint(x: 15, y: 15))
        details.line(to: NSPoint(x: 21, y: 15))
        details.move(to: NSPoint(x: 7, y: 11))
        details.line(to: NSPoint(x: 11, y: 11))
        details.move(to: NSPoint(x: 7, y: 7))
        details.line(to: NSPoint(x: 17, y: 7))
        details.lineWidth = 1.8
        details.lineCapStyle = .round
        details.lineJoinStyle = .round
        details.stroke()
    }
}
