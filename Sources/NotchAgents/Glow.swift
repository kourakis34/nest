import AppKit
import QuartzCore

enum GlowColors {
    static let rainbow: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.23, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.93, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.90, blue: 0.40, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.60, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.70, green: 0.35, blue: 1.00, alpha: 1),
    ]

    /// "#RRGGBB" → one color, "rainbow" → the rainbow.
    static func parse(_ spec: String) -> [NSColor] {
        let s = spec.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "rainbow" { return rainbow }
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return [.white] }
        return [NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                        green: CGFloat((v >> 8) & 0xFF) / 255,
                        blue: CGFloat(v & 0xFF) / 255, alpha: 1)]
    }
}

/// A glowing neon stroke along a path: a soft wide halo, a mid glow and a bright core.
/// Several colors are laid out as a slowly rotating conic gradient.
final class NeonLayer: CALayer {
    private var path: CGPath?

    /// Stroke widths and opacities, outermost halo first.
    static let normalStrokes: [(CGFloat, Float)] = [(18, 0.45), (10, 0.75), (4.5, 1), (2.5, 1)]
    /// Much wider, brighter bloom used for the "done" flash.
    static let flashStrokes: [(CGFloat, Float)] = [(46, 0.35), (28, 0.6), (15, 0.9), (7, 1), (3.5, 1)]

    func configure(path: CGPath, colors: [NSColor], breathing: Bool,
                   strokes: [(CGFloat, Float)] = NeonLayer.normalStrokes) {
        self.path = path
        sublayers?.forEach { $0.removeFromSuperlayer() }
        removeAllAnimations()

        let cgColors: [CGColor]
        if colors.count <= 1 {
            let c = (colors.first ?? .white).cgColor
            cgColors = [c, c]
        } else {
            cgColors = colors.map(\.cgColor) + [colors[0].cgColor] // wrap so the seam is invisible
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        contentsScale = scale
        let side = hypot(bounds.width, bounds.height)
        for (width, alpha) in strokes {
            let stroke = CAShapeLayer()
            stroke.frame = bounds
            stroke.contentsScale = scale
            stroke.path = path
            stroke.fillColor = nil
            stroke.strokeColor = NSColor.black.cgColor
            stroke.lineWidth = width
            stroke.lineCap = .round
            stroke.lineJoin = .round

            let holder = CALayer()
            holder.frame = bounds
            holder.mask = stroke
            holder.opacity = alpha

            let gradient = CAGradientLayer()
            gradient.contentsScale = scale
            gradient.type = .conic
            gradient.colors = cgColors
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            if colors.count > 1 {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -2 * Double.pi
                spin.duration = 4
                spin.repeatCount = .infinity
                gradient.add(spin, forKey: "spin")
            }
            holder.addSublayer(gradient)
            addSublayer(holder)
        }

        opacity = 1
        if breathing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.8
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            add(pulse, forKey: "breathe")
        }
    }

    /// Two quick bright pulses in `color`, then fade to nothing.
    func flash(color: NSColor, completion: @escaping () -> Void) {
        guard let path else { completion(); return }
        configure(path: path, colors: [color], breathing: false, strokes: NeonLayer.flashStrokes)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        // Three bright pulses, holding on the last before fading out.
        anim.values = [0, 1, 0.5, 1, 0.5, 1, 1, 0]
        anim.keyTimes = [0, 0.08, 0.2, 0.3, 0.42, 0.52, 0.75, 1]
        anim.duration = 2.4
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        add(anim, forKey: "flash")
        CATransaction.commit()
    }

    func clear() {
        removeAllAnimations()
        sublayers?.forEach { $0.removeFromSuperlayer() }
    }
}

/// A click-through window hugging the notch that draws the neon outline around it.
final class GlowOverlay {
    private let panel = NotchPanel()
    private let neon = NeonLayer()
    private var geometry: NotchGeometry?
    private var colors: [NSColor] = []
    private var flashing = false

    /// Room around the notch for the glow to spread.
    private let margin: CGFloat = 46
    /// Bottom-corner radius of the camera housing.
    private let notchRadius: CGFloat = 9

    init() {
        panel.ignoresMouseEvents = true
        // One level below the hover tray, so an open tray covers the outline.
        panel.level = .statusBar
        let content = NSView()
        content.wantsLayer = true
        content.layer?.addSublayer(neon)
        panel.contentView = content
    }

    func update(geometry: NotchGeometry) {
        self.geometry = geometry
        let width = geometry.notchMaxX - geometry.notchMinX + margin * 2
        let height = geometry.barHeight + margin
        panel.setFrame(NSRect(x: geometry.notchMinX - margin, y: geometry.screenTop - height,
                              width: width, height: height), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        neon.frame = CGRect(x: 0, y: 0, width: width, height: height)
        CATransaction.commit()
        render()
    }

    /// Colors of the agents currently working (empty = hide).
    func show(colors: [NSColor]) {
        self.colors = colors
        if !flashing { render() }
    }

    func flash(color: NSColor) {
        guard geometry != nil else { return }
        flashing = true
        panel.orderFrontRegardless()
        neon.flash(color: color) { [weak self] in
            guard let self else { return }
            self.flashing = false
            self.render()
        }
    }

    private func render() {
        guard geometry != nil else { return }
        if colors.isEmpty {
            neon.clear()
            panel.orderOut(nil)
            return
        }
        neon.configure(path: notchPath(), colors: colors, breathing: true)
        panel.orderFrontRegardless()
    }

    /// The outline of the camera housing (sides and rounded bottom), just outside its edge.
    private func notchPath() -> CGPath {
        let b = neon.bounds
        let inset: CGFloat = 1.5
        let left = margin - inset
        let right = b.width - margin + inset
        let bottom = margin - inset
        let top = b.height + 4                 // run off the top of the screen
        let r = notchRadius + inset

        let p = CGMutablePath()
        p.move(to: CGPoint(x: left, y: top))
        p.addLine(to: CGPoint(x: left, y: bottom + r))
        p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + r, y: bottom), radius: r)
        p.addLine(to: CGPoint(x: right - r, y: bottom))
        p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom + r), radius: r)
        p.addLine(to: CGPoint(x: right, y: top))
        return p
    }
}
