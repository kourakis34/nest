import AppKit
import ApplicationServices

/// Watches every agent and reports which ones are working on a prompt,
/// plus a "finished" event when one is done.
///
/// Detection is necessarily indirect, since none of these apps publish a status:
///  - iMessage agents: read ~/Library/Messages/chat.db. If the last message in the
///    chat is from you (and recent), the agent is working; when its reply lands, it's done.
///    Needs Full Disk Access for NotchAgents.
///  - App agents (default): look for the app's "Stop" button via Accessibility
///    (see ButtonDetector). Visible = working, gone = done.
///  - App agents with "activity": "cpu": CPU use of the window processes compared with
///    the app's learned idle level (a heuristic; less reliable).
final class ActivityMonitor {
    /// Called on the main thread with the names of agents currently working.
    var onChange: ((Set<String>) -> Void)?
    /// Called on the main thread when an agent finishes a prompt.
    var onFinished: ((String) -> Void)?

    private var appNeedsFDA = false
    var needsFullDiskAccess: Bool {
        get { appNeedsFDA || messageWatchers.contains { $0.accessDenied } }
        set { appNeedsFDA = newValue }
    }
    private(set) var needsAccessibility = false
    /// App paths of agents using button detection, for the "Show Button Names" tool.
    private(set) var buttonApps: [(name: String, path: String)] = []
    private var polling = false
    /// Latest per-agent reading, shown in the right-click menu for tuning.
    private var appReadings: [(name: String, text: String)] = []
    var readings: [(name: String, text: String)] {
        messageWatchers.map { (name: $0.name, text: $0.state) } + appReadings
    }

    private let queue = DispatchQueue(label: "NotchAgents.activity")
    private var timer: Timer?
    private var detectors: [(name: String, detector: ActivityDetector)] = []
    private var active: Set<String> = []          // from polled detectors (apps)
    private var messageActive: Set<String> = []   // from Messages watchers
    private var published: Set<String> = []
    private var messageWatchers: [MessagesWatcher] = []
    private var sampler = CPUSampler()

    func configure(agents: [AgentConfig], enabled: Bool) {
        messageWatchers.forEach { $0.stop() }
        messageWatchers = []
        messageActive = []
        var watchers: [MessagesWatcher] = []
        var list: [(String, ActivityDetector)] = []
        if enabled {
            for agent in agents {
                switch agent.resolvedActivity {
                case "imessage":
                    if let handle = agent.action.handle, !handle.hasPrefix("REPLACE_") {
                        watchers.append(MessagesWatcher(name: agent.name, handle: handle))
                    }
                case "buttons":
                    if let url = Launcher.appURL(for: agent.action) {
                        let detector: ActivityDetector = ButtonDetector(appPath: url.path, patterns: agent.stopButtons,
                                                                      watchText: agent.resolvedWatchText,
                                                                      backgroundFallback: agent.resolvedBackgroundDone,
                                                                      responseButtons: agent.resolvedResponseButtons)
                        list.append((agent.name, detector))
                    }
                case "cpu":
                    // Resolve the app on the main thread (it may hit Spotlight once, then is cached).
                    if let url = Launcher.appURL(for: agent.action) {
                        let detector: ActivityDetector = CPUDetector(appPath: url.path,
                                                                     threshold: agent.cpuThreshold ?? 8)
                        list.append((agent.name, detector))
                    }
                default:
                    break
                }
            }
        }
        for watcher in watchers {
            watcher.onChange = { [weak self, weak watcher] working in
                guard let self, let watcher else { return }
                if working { self.messageActive.insert(watcher.name) } else { self.messageActive.remove(watcher.name) }
                self.publish()
            }
            watcher.onFinished = { [weak self, weak watcher] in
                guard let watcher else { return }
                self?.onFinished?(watcher.name)
            }
            watcher.start()
        }
        messageWatchers = watchers
        publish()

        buttonApps = agents.compactMap { agent -> (name: String, path: String)? in
            guard agent.resolvedActivity == "buttons", enabled,
                  let url = Launcher.appURL(for: agent.action) else { return nil }
            return (agent.name, url.path)
        }
        if !buttonApps.isEmpty && !AXIsProcessTrusted() {
            // Shows the system prompt (once) that leads to the Accessibility settings.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        queue.async { [weak self] in
            self?.detectors = list.map { (name: $0.0, detector: $0.1) }
        }
        if list.isEmpty {
            timer?.invalidate(); timer = nil
            active = []
            publish()
        } else if timer == nil {
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// A plain-text report of what every detector currently sees, for troubleshooting.
    func diagnostics() -> String {
        var lines: [String] = []
        lines.append("Accessibility permission: \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
        for w in messageWatchers {
            lines.append("")
            lines.append("\(w.name) (iMessage):")
            lines.append("  state: \(w.state)")
            lines.append("  Full Disk Access: \(w.accessDenied ? "NOT granted (can't read Messages)" : "ok")")
        }
        let snapshot: [(String, String)] = queue.sync {
            detectors.map { entry -> (String, String) in
                if let b = entry.detector as? ButtonDetector { return (entry.name + " (Stop button):", b.diagnostics) }
                if let c = entry.detector as? CPUDetector { return (entry.name + " (CPU):", "  " + c.reading) }
                return (entry.name + ":", "  (unknown detector)")
            }
        }
        for (title, body) in snapshot {
            lines.append("")
            lines.append(title)
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    private func publish() {
        let all = active.union(messageActive)
        guard all != published else { return }
        published = all
        onChange?(all)
    }

    private func poll() {
        // Accessibility scans can take a moment; never let polls pile up.
        guard !polling else { return }
        polling = true
        queue.async { [weak self] in
            guard let self else { return }
            let cpuApps = self.detectors.compactMap { $0.detector.cpuAppPath }
            let usage = cpuApps.isEmpty ? [:] : self.sampler.sample(appPaths: cpuApps)

            var nowActive: Set<String> = []
            var finished: [String] = []
            let needsFDA = false
            var needsAX = false
            var readings: [(name: String, text: String)] = []
            for (name, detector) in self.detectors {
                let result = detector.poll(cpu: usage)
                if result.working { nowActive.insert(name) }
                if result.finished { finished.append(name) }
                if let buttons = detector as? ButtonDetector {
                    if buttons.needsPermission { needsAX = true }
                    readings.append((name, buttons.state))
                } else if let cpu = detector as? CPUDetector {
                    readings.append((name, cpu.reading))
                }
            }

            DispatchQueue.main.async {
                self.polling = false
                self.needsFullDiskAccess = needsFDA
                self.needsAccessibility = needsAX
                self.appReadings = readings
                if nowActive != self.active {
                    self.active = nowActive
                    self.publish()
                }
                finished.forEach { self.onFinished?($0) }
            }
        }
    }
}

struct PollResult {
    var working: Bool
    var finished: Bool
}

protocol ActivityDetector: AnyObject {
    /// `cpu` maps executable path → CPU percent over the last interval
    /// (only processes inside apps that asked for CPU via `cpuAppPath`).
    func poll(cpu: [String: Double]) -> PollResult
    /// The app whose CPU use this detector needs measured, if any.
    var cpuAppPath: String? { get }
}

final class CPUDetector: ActivityDetector {
    private let prefix: String
    /// Extra CPU percent above the app's own idle level that counts as working.
    private let rise: Double
    private var runningSince: Date?
    private var workingSince: Date?
    private var above = 0
    private var below = 0
    /// Recent readings (one per second), used to learn the app's idle level.
    private var history: [Double] = []
    private let historyLength = 180
    /// Never show "working" longer than this without a break (safety net).
    private let maxWorking: TimeInterval = 5 * 60

    private(set) var lastReading = 0.0
    private(set) var baseline = 0.0
    private(set) var usingRenderers = false

    let cpuAppPath: String?

    init(appPath: String, threshold: Double) {
        prefix = appPath.hasSuffix("/") ? appPath : appPath + "/"
        cpuAppPath = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
        rise = threshold
    }

    func poll(cpu: [String: Double]) -> PollResult {
        // Electron apps (Claude, etc.) run background helpers (GPU, network, MCP servers,
        // VMs) that use CPU even when idle. Streaming a reply shows up in the window's
        // renderer process, so when the app has renderers, only count those.
        var running = false
        var all = 0.0
        var renderers = 0.0
        var hasRenderer = false
        for (path, pct) in cpu where path.hasPrefix(prefix) {
            running = true
            all += pct
            if path.contains("(Renderer)") { hasRenderer = true; renderers += pct }
        }
        let total = hasRenderer ? renderers : all
        usingRenderers = hasRenderer
        lastReading = total
        let now = Date()

        guard running else {
            // App quit: clear quietly, no "finished" flash.
            runningSince = nil; workingSince = nil; above = 0; below = 0; history = []
            return PollResult(working: false, finished: false)
        }
        if runningSince == nil { runningSince = now }

        history.append(total)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }

        // Ignore launch, and wait until there's enough history to know the idle level.
        if now.timeIntervalSince(runningSince!) < 8 || history.count < 10 {
            return PollResult(working: false, finished: false)
        }

        // Idle level = a low percentile of recent readings, so short bursts don't move it.
        let sorted = history.sorted()
        baseline = sorted[Int(Double(sorted.count - 1) * 0.25)]
        let margin = max(rise, baseline * 0.5)
        let onLevel = baseline + margin
        let offLevel = baseline + margin * 0.5

        if let since = workingSince {
            below = total < offLevel ? below + 1 : 0
            let tooLong = now.timeIntervalSince(since) > maxWorking
            if below >= 3 || tooLong {
                workingSince = nil; above = 0; below = 0
                if tooLong { history = [] }   // relearn the idle level
                // Only celebrate real work, not a brief blip.
                return PollResult(working: false, finished: !tooLong && now.timeIntervalSince(since) >= 4)
            }
            return PollResult(working: true, finished: false)
        } else {
            above = total >= onLevel ? above + 1 : 0
            if above >= 3 { workingSince = now; below = 0 }
            return PollResult(working: workingSince != nil, finished: false)
        }
    }

    var reading: String {
        let source = usingRenderers ? "window" : "app"
        if history.count < 10 { return String(format: "%.0f%% %@ CPU (learning idle level…)", lastReading, source) }
        let state = workingSince != nil ? "working" : "idle"
        return String(format: "%.0f%% %@ CPU, idle ≈ %.0f%% → %@", lastReading, source, baseline, state)
    }
}
