import AppKit

/// A single clickable agent icon sitting beside the notch.
final class AgentIconView: NSView {
    let agent: AgentConfig
    var contextMenuProvider: (() -> NSMenu)?
    /// Called after the agent is launched (used to close the hover tray).
    var onActivate: (() -> Void)?

    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { updateAppearance() } }
    private var isPressed = false { didSet { updateAppearance() } }

    init(agent: AgentConfig, size: CGFloat) {
        self.agent = agent
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size * 0.25

        imageView.frame = bounds.insetBy(dx: size * 0.08, dy: size * 0.08)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = IconResolver.image(for: agent, size: size)
        // SF Symbols render as templates; draw them white so they read on the black notch strip.
        imageView.contentTintColor = .white
        addSubview(imageView)

        toolTip = agent.name
        setAccessibilityRole(.button)
        setAccessibilityLabel(agent.name)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Clicks must register even though our panel never becomes key/active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(event); return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            Launcher.run(agent)
            onActivate?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    private func showMenu(_ event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Activity ring

    private lazy var neon: NeonLayer = {
        let n = NeonLayer()
        n.frame = self.bounds
        self.layer?.insertSublayer(n, at: 0)
        return n
    }()

    private var ringPath: CGPath {
        let r = bounds.insetBy(dx: 2, dy: 2)
        return CGPath(roundedRect: r, cornerWidth: bounds.width * 0.24, cornerHeight: bounds.width * 0.24, transform: nil)
    }

    /// Show a breathing neon ring while this agent is working (nil = off).
    func setWorking(_ colors: [NSColor]?) {
        if let colors {
            neon.configure(path: ringPath, colors: colors, breathing: true)
        } else {
            neon.clear()
        }
    }

    func flashDone(_ color: NSColor) {
        neon.configure(path: ringPath, colors: [color], breathing: false, strokes: NeonLayer.flashStrokes)
        neon.flash(color: color) { [weak self] in self?.neon.clear() }
    }

    private func updateAppearance() {
        let bg: NSColor
        if isPressed { bg = NSColor.white.withAlphaComponent(0.30) }
        else if isHovered { bg = NSColor.white.withAlphaComponent(0.15) }
        else { bg = .clear }
        layer?.backgroundColor = bg.cgColor
        imageView.alphaValue = isPressed ? 0.75 : 1.0
    }
}

enum IconResolver {
    static func image(for agent: AgentConfig, size: CGFloat) -> NSImage {
        if let spec = agent.icon?.trimmingCharacters(in: .whitespaces), !spec.isEmpty {
            if spec == "builtin:instinct" {
                return instinctIcon(size: size)
            } else if spec == "builtin:robot" {
                return robotIcon(size: size)
            } else if spec.hasPrefix("sf:") {
                let name = String(spec.dropFirst(3))
                let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .semibold)
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: agent.name)?
                    .withSymbolConfiguration(cfg) {
                    return img
                }
            } else if spec.hasPrefix("app:") {
                let id = String(spec.dropFirst(4))
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return NSWorkspace.shared.icon(forFile: url.path)
                }
            } else {
                let path = (spec as NSString).expandingTildeInPath
                if let img = NSImage(contentsOfFile: path) { return img }
            }
        }

        // No explicit icon: a user-supplied image named after the agent wins...
        for ext in ["png", "icns", "jpg", "jpeg"] {
            let file = ConfigStore.iconsDirectory.appendingPathComponent("\(agent.name.lowercased()).\(ext)")
            if let img = NSImage(contentsOf: file) { return img }
        }
        // ...then one bundled with the app (Resources/icons/<name>.png)...
        if let url = Bundle.main.url(forResource: agent.name.lowercased(), withExtension: "png", subdirectory: "icons"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        // ...then the target's own icon.
        switch agent.action.type.lowercased() {
        case "app":
            if let url = Launcher.appURL(for: agent.action) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        case "imessage", "messages":
            if let url = Launcher.messagesAppURL {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        default:
            break
        }
        return letterIcon(agent.name, size: size)
    }

    /// Instinct: a white circle with a slender black serif "I". Drawn as vector
    /// shapes so it stays crisp at any size / on Retina screens.
    static func instinctIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let s = r.width
            func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> NSRect {
                NSRect(x: x0 * s, y: y0 * s, width: (x1 - x0) * s, height: (y1 - y0) * s)
            }
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }

            NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect(0.02, 0.02, 0.98, 0.98)).fill()

            NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
            // Stem
            NSBezierPath(rect: rect(0.477, 0.25, 0.523, 0.75)).fill()
            // Top and bottom serifs
            NSBezierPath(rect: rect(0.425, 0.747, 0.575, 0.765)).fill()
            NSBezierPath(rect: rect(0.425, 0.235, 0.575, 0.253)).fill()
            // Brackets joining the serifs to the stem
            for (serifY, innerY) in [(CGFloat(0.747), CGFloat(0.715)), (CGFloat(0.253), CGFloat(0.285))] {
                for side: CGFloat in [-1, 1] {
                    let bracket = NSBezierPath()
                    bracket.move(to: pt(0.5 + side * 0.023, serifY))
                    bracket.line(to: pt(0.5 + side * 0.06, serifY))
                    bracket.line(to: pt(0.5 + side * 0.023, innerY))
                    bracket.close()
                    bracket.fill()
                }
            }
            return true
        }
    }

    /// A simple, neutral robot head drawn as a single-color line icon.
    static func robotIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let s = r.width
            func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> NSRect {
                NSRect(x: x0 * s, y: y0 * s, width: (x1 - x0) * s, height: (y1 - y0) * s)
            }
            let ink = NSColor(calibratedWhite: 0.94, alpha: 1)
            let line = max(1.5, 0.075 * s)
            ink.setFill()
            ink.setStroke()

            // Antenna
            let stalk = NSBezierPath()
            stalk.move(to: NSPoint(x: 0.5 * s, y: 0.72 * s))
            stalk.line(to: NSPoint(x: 0.5 * s, y: 0.84 * s))
            stalk.lineWidth = line
            stalk.stroke()
            NSBezierPath(ovalIn: rect(0.435, 0.81, 0.565, 0.94)).fill()

            // Ears
            NSBezierPath(roundedRect: rect(0.05, 0.33, 0.13, 0.53), xRadius: 0.03 * s, yRadius: 0.03 * s).fill()
            NSBezierPath(roundedRect: rect(0.87, 0.33, 0.95, 0.53), xRadius: 0.03 * s, yRadius: 0.03 * s).fill()

            // Head outline (inset by half the line width so the stroke stays inside the box)
            let half = line / 2 / s
            let head = NSBezierPath(roundedRect: rect(0.17 + half, 0.12 + half, 0.83 - half, 0.72 - half),
                                    xRadius: 0.15 * s, yRadius: 0.15 * s)
            head.lineWidth = line
            head.stroke()

            // Eyes
            NSBezierPath(ovalIn: rect(0.32, 0.37, 0.43, 0.48)).fill()
            NSBezierPath(ovalIn: rect(0.57, 0.37, 0.68, 0.48)).fill()
            return true
        }
    }

    /// Fallback: a rounded square with the agent's first letter.
    static func letterIcon(_ name: String, size: CGFloat) -> NSImage {
        let letter = String(name.first ?? "?").uppercased()
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: size * 0.22, yRadius: size * 0.22)
            NSColor.white.withAlphaComponent(0.18).setFill()
            path.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.55, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let str = NSAttributedString(string: letter, attributes: attrs)
            let s = str.size()
            str.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
            return true
        }
    }
}
