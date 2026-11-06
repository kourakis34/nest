import AppKit

/// Borderless, non-activating panel that floats above the menu bar.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Above the menu bar and status items.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the on-screen UI and switches between "hover" and "wings" modes.
final class NotchController {
    private let wings = WingsLayout()
    private let tray = HoverTray()
    private let glow = GlowOverlay()
    private let monitor = ActivityMonitor()
    private var config: AppConfig = .default
    private var working: Set<String> = []

    var contextMenuProvider: (() -> NSMenu)? {
        didSet { wings.contextMenuProvider = contextMenuProvider; tray.contextMenuProvider = contextMenuProvider }
    }

    /// True when Instinct's status can't be read because Full Disk Access is missing.
    var needsFullDiskAccess: Bool { monitor.needsFullDiskAccess }
    var needsAccessibility: Bool { monitor.needsAccessibility }
    var buttonApps: [(name: String, path: String)] { monitor.buttonApps }
    func activityDiagnostics() -> String { monitor.diagnostics() }

    /// Live detection readings per agent, for the right-click menu.
    var activityReadings: [(name: String, text: String)] { monitor.readings }

    init() {
        monitor.onChange = { [weak self] names in
            self?.working = names
            self?.renderActivity()
        }
        monitor.onFinished = { [weak self] name in self?.finished(name) }
    }

    func apply(_ config: AppConfig) {
        self.config = config
        monitor.configure(agents: config.left + config.right, enabled: config.showActivity)
        layout()
    }

    func layout() {
        guard let geometry = NotchGeometry.current() else {
            wings.hide(); tray.stop(); glow.show(colors: []); return
        }
        if config.mode.lowercased() == "wings" {
            tray.stop()
            wings.layout(config: config, geometry: geometry)
        } else {
            wings.hide()
            tray.start(config: config, geometry: geometry)
        }
        glow.update(geometry: geometry)
        renderActivity()
    }

    private var iconViews: [AgentIconView] { tray.iconViews + wings.iconViews }

    private func renderActivity() {
        let agents = config.left + config.right
        // Colors of every working agent, in tray order; several at once blend into a rotating ring.
        var colors: [NSColor] = []
        for agent in agents where working.contains(agent.name) {
            colors += GlowColors.parse(agent.resolvedGlow)
        }
        glow.show(colors: colors)
        for view in iconViews {
            view.setWorking(working.contains(view.agent.name) ? GlowColors.parse(view.agent.resolvedGlow) : nil)
        }
    }

    private func finished(_ name: String) {
        let green = GlowColors.parse(config.doneColor).first ?? .green
        glow.flash(color: green)
        iconViews.first { $0.agent.name == name }?.flashDone(green)
    }
}

// MARK: - Hover mode: a tray that drops out of the notch

final class HoverTray {
    var contextMenuProvider: (() -> NSMenu)?
    private(set) var iconViews: [AgentIconView] = []

    private let panel = NotchPanel()
    private var timer: Timer?
    private var geometry: NotchGeometry?
    private var expandedFrame: NSRect = .zero
    private var collapsedFrame: NSRect = .zero
    private var isOpen = false


    func start(config: AppConfig, geometry: NotchGeometry) {
        self.geometry = geometry
        build(config: config, geometry: geometry)
        if timer == nil {
            // Polling the cursor position needs no special permissions and costs next to nothing.
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isOpen = false
        iconViews = []
        panel.orderOut(nil)
    }

    private func build(config: AppConfig, geometry g: NotchGeometry) {
        let groups = [config.left, config.right].filter { !$0.isEmpty }
        let size = CGFloat(config.iconSize > 0 ? config.iconSize : 62)
        let spacing = CGFloat(config.spacing) * 1.75
        let groupGap = spacing * 4          // a little extra room where the camera sits
        let sidePad: CGFloat = 30
        let bottomPad: CGFloat = 20
        let topPad: CGFloat = 16

        let count = groups.reduce(0) { $0 + $1.count }
        var iconsWidth = CGFloat(count) * size + CGFloat(max(0, count - groups.count)) * spacing
        if groups.count > 1 { iconsWidth += groupGap }

        let notchWidth = g.notchMaxX - g.notchMinX
        let width = max(iconsWidth + sidePad * 2, notchWidth + 80)
        let height = g.barHeight + topPad + size + bottomPad
        let midX = (g.notchMinX + g.notchMaxX) / 2

        expandedFrame = NSRect(x: midX - width / 2, y: g.screenTop - height, width: width, height: height)
        collapsedFrame = NSRect(x: g.notchMinX, y: g.screenTop - g.barHeight,
                                width: max(notchWidth, 1), height: g.barHeight)

        // Black backdrop with rounded bottom corners, so it reads as the notch growing downward.
        let content = NSView(frame: NSRect(origin: .zero, size: expandedFrame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 30
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        content.layer?.masksToBounds = true

        // Icons live in a fixed-size container pinned to the top-center, so they are
        // revealed (not squashed) while the panel animates open.
        let container = NSView(frame: content.bounds)
        container.autoresizingMask = [.minYMargin, .minXMargin, .maxXMargin]
        content.addSubview(container)

        iconViews = []
        var x = (width - iconsWidth) / 2
        for (gi, group) in groups.enumerated() {
            if gi > 0 { x += groupGap - spacing }
            for agent in group {
                let view = AgentIconView(agent: agent, size: size)
                view.frame.origin = NSPoint(x: x, y: bottomPad)
                view.contextMenuProvider = contextMenuProvider
                view.onActivate = { [weak self] in self?.close(animated: true) }
                container.addSubview(view)
                iconViews.append(view)
                x += size + spacing
            }
        }

        panel.contentView = content
        panel.setFrame(isOpen ? expandedFrame : collapsedFrame, display: true)
        if isOpen { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func tick() {
        guard let g = geometry else { return }
        let mouse = NSEvent.mouseLocation

        // The notch itself. On Macs without a notch, a thin strip at the top center.
        let hotHeight = g.hasNotch ? g.barHeight : 4
        let hot = NSRect(x: g.notchMinX, y: g.screenTop - hotHeight,
                         width: g.notchMaxX - g.notchMinX, height: hotHeight + 2)
        let inHot = hot.contains(mouse)
        let inTray = isOpen && expandedFrame.contains(mouse)

        if inHot && !isOpen {
            open()
        } else if isOpen && !inHot && !inTray {
            // Shrink back the moment the mouse leaves the notch/tray.
            close(animated: true)
        }
    }

    private func open() {
        isOpen = true
        panel.setFrame(collapsedFrame, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(expandedFrame, display: true)
        }
    }

    private func close(animated: Bool) {
        guard isOpen else { return }
        isOpen = false
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(collapsedFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self, !self.isOpen else { return }
            self.panel.orderOut(nil)
        })
    }
}

// MARK: - Wings mode: icons always visible beside the notch

final class WingsLayout {
    enum Side { case left, right }

    var contextMenuProvider: (() -> NSMenu)?
    private(set) var iconViews: [AgentIconView] = []
    private let leftPanel = NotchPanel()
    private let rightPanel = NotchPanel()

    func hide() {
        iconViews = []
        leftPanel.orderOut(nil)
        rightPanel.orderOut(nil)
    }

    func layout(config: AppConfig, geometry: NotchGeometry) {
        iconViews = []
        build(panel: leftPanel, agents: config.left, side: .left, config: config, geometry: geometry)
        build(panel: rightPanel, agents: config.right, side: .right, config: config, geometry: geometry)
    }

    private func build(panel: NotchPanel, agents: [AgentConfig], side: Side,
                       config: AppConfig, geometry: NotchGeometry) {
        guard !agents.isEmpty else { panel.orderOut(nil); return }

        let barHeight = geometry.barHeight
        let size = CGFloat(config.iconSize > 0 ? config.iconSize : max(16, Double(barHeight) - 6))
        let spacing = CGFloat(config.spacing)
        let innerPad = CGFloat(config.notchPadding)   // gap next to the notch
        let outerPad: CGFloat = config.extendNotch ? max(8, barHeight * 0.4) : 2

        let iconsWidth = CGFloat(agents.count) * size + CGFloat(agents.count - 1) * spacing
        let width = iconsWidth + innerPad + outerPad
        let height = max(barHeight, size)

        let x = side == .left ? geometry.notchMinX - width : geometry.notchMaxX
        let y = geometry.screenTop - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        if config.extendNotch {
            content.layer?.backgroundColor = NSColor.black.cgColor
            content.layer?.cornerRadius = min(height / 2, 10)
            // Round only the outer bottom corner so the strip merges into the notch.
            content.layer?.maskedCorners = side == .left ? [.layerMinXMinYCorner] : [.layerMaxXMinYCorner]
        }

        var cursor = side == .left ? outerPad : innerPad
        for agent in agents {
            let view = AgentIconView(agent: agent, size: size)
            view.frame.origin = NSPoint(x: cursor, y: (height - size) / 2)
            view.contextMenuProvider = contextMenuProvider
            content.addSubview(view)
            iconViews.append(view)
            cursor += size + spacing
        }

        panel.contentView = content
        panel.orderFrontRegardless()
    }
}

// MARK: - Geometry

/// Where the notch is on screen (or a virtual one on Macs without a notch).
struct NotchGeometry {
    var notchMinX: CGFloat
    var notchMaxX: CGFloat
    var screenTop: CGFloat
    var barHeight: CGFloat
    var hasNotch: Bool

    static func current() -> NotchGeometry? {
        let screens = NSScreen.screens
        // Prefer the built-in display with a camera housing.
        if let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            return NotchGeometry(notchMinX: leftArea.maxX,
                                 notchMaxX: rightArea.minX,
                                 screenTop: screen.frame.maxY,
                                 barHeight: screen.safeAreaInsets.top,
                                 hasNotch: true)
        }
        // No notch (external display / older Mac): pretend there's one centered at the top.
        guard let screen = NSScreen.main ?? screens.first else { return nil }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let barHeight = menuBar > 0 ? menuBar : 24
        let halfGap: CGFloat = 100
        return NotchGeometry(notchMinX: screen.frame.midX - halfGap,
                             notchMaxX: screen.frame.midX + halfGap,
                             screenTop: screen.frame.maxY,
                             barHeight: barHeight,
                             hasNotch: false)
    }
}
