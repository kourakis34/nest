import AppKit
import ApplicationServices

/// Detects that an app is generating a reply by looking for its "Stop" button
/// through the macOS Accessibility API. Chat apps show a stop control only while
/// a response is streaming, so: button visible = working, button gone = done.
///
/// Performance matters: every Accessibility call is a round-trip to the other app,
/// and a chat window can contain thousands of elements. So:
///  - each element is read with ONE call (role, labels and children together);
///  - inside web content (Claude and other Electron/Chromium apps) we don't walk the
///    tree element by element: we ask the web area for its buttons directly, the same
///    search VoiceOver uses ("AXUIElementsForSearchPredicate");
///  - where the button was last seen is checked first.
///
/// Requires Accessibility permission for NotchAgents
/// (System Settings → Privacy & Security → Accessibility).
final class ButtonDetector: ActivityDetector {
    let appPath: String
    private let patterns: [String]

    private var pid: pid_t?
    private var appElement: AXUIElement?
    /// The chat box (area around the Send/Stop button); searched first (cheap).
    private var hotContainer: AXUIElement?
    /// Web content areas found in the app's windows (searched with the fast predicate).
    private var webAreas: [AXUIElement] = []
    private var lastFullScan = Date.distantPast
    /// Full scans: often while you're looking at the app (fresh, cheap to get right),
    /// less often in the background.
    private var fullScanInterval: TimeInterval { wasFrontmost ? 3 : 8 }
    private var wasFrontmost = false
    private var bundleID: String?
    /// Newest notification ID seen from this app before the current background stretch.
    private var notificationBaseline: Int64?
    /// Whether this app is known to post notifications (any are on record).
    private var postsNotifications = false
    /// Give up on a background reply after this long with no notification.
    private let backgroundLimit: TimeInterval = 30 * 60
    /// Whether the last check saw the Stop button (a disappearance gets double-checked).
    private var lastFound = false
    private var working = false
    private var workingSince: Date?
    private var missCount = 0

    private(set) var state = "starting"
    private(set) var needsPermission = false

    // Diagnostics (shown in the "Copy Diagnostics" report)
    private(set) var lastScan = AXSearch.ScanStats()
    private(set) var lastMatch: String?

    static let defaultPatterns = ["stop", "stop response", "stop generating", "stop streaming",
                                  "stop responding", "stop answer", "stop generation"]

    /// Also treat reply text streaming into the window as "working" (for apps whose
    /// stop button has no usable label).
    private let watchText: Bool
    private var lastTextLength: Int?
    private var growCount = 0
    private var quietCount = 0
    private var textActive = false

    /// Web-based apps (Claude) stop refreshing their accessibility tree while their window
    /// is in the background, so a finished reply can keep showing a stale Stop button.
    /// With this on, while the app is in the background its window processes going quiet
    /// for a few seconds also counts as "done".
    let backgroundFallback: Bool
    private var quietBackgroundPolls = 0
    /// Set after a background "done": ignore the (stale) Stop button until it disappears
    /// or the app is brought to the front and it's still there.
    private var staleButton = false
    private var frontFoundPolls = 0

    var cpuAppPath: String? { backgroundFallback ? appPath : nil }

    /// Response tracking (Muse): apps whose finished replies each get a button such as
    /// "Copy response", but that show no labeled Stop button. Sending a message (the chat
    /// grows a little) = working; a new response button appearing = done.
    private let responsePatterns: [String]
    private var responseCount: Int?
    private var pending = false
    private var pendingSince: Date?
    private let pendingTimeout: TimeInterval = 3 * 60

    init(appPath: String, patterns: [String]?, watchText: Bool = false, backgroundFallback: Bool = false,
         responseButtons: [String] = []) {
        self.responsePatterns = responseButtons.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.watchText = watchText
        self.backgroundFallback = backgroundFallback
        self.appPath = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
        let p = (patterns?.isEmpty == false ? patterns! : Self.defaultPatterns)
        self.patterns = p.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func poll(cpu: [String: Double]) -> PollResult {
        guard AXIsProcessTrusted() else {
            needsPermission = true
            state = "no Accessibility permission for this build (use Fix Permissions…)"
            return PollResult(working: false, finished: false)
        }
        needsPermission = false

        guard let app = currentAppElement() else {
            reset()
            state = "not running"
            return PollResult(working: false, finished: false)
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if frontmost && !wasFrontmost {
            // Just came to the front: its accessibility tree is fresh again, so drop what we
            // cached while it was hidden and scan the whole window right now.
            lastFullScan = .distantPast
            hotContainer = nil
            webAreas = []
        }
        wasFrontmost = frontmost
        var found = findStopButton(app: app)

        // Notification baseline: anything newer than this, posted while the app is in the
        // background, means the reply finished.
        let notes = bundleID.flatMap { NotificationWatcher.shared.latest(bundleID: $0) }
        if let notes, notes.count > 0 { postsNotifications = true }
        if !(backgroundFallback && working && !frontmost) {
            notificationBaseline = notes?.newestID
        }

        // A background "done" already fired: the Stop button we still see is stale.
        if staleButton {
            if !found {
                staleButton = false; frontFoundPolls = 0
            } else if frontmost {
                // In front the tree is fresh; if the button persists, it's a new prompt.
                frontFoundPolls += 1
                if frontFoundPolls >= 3 { staleButton = false; frontFoundPolls = 0 } else { found = false }
            } else {
                found = false
            }
        }

        // Background (another app in front, another desktop, full screen elsewhere):
        // web-based apps stop updating what Accessibility sees, and hidden windows barely
        // use CPU even mid-reply. So once working, stay working until:
        //  1. the app posts a notification (e.g. Claude's "response finished"), or
        //  2. it comes back to the front (then the Stop button is trustworthy again), or
        //  3. for apps that never post notifications: its processes stay quiet ~15 s, or
        //  4. a 30-minute safety limit.
        if backgroundFallback, working, !frontmost {
            let elapsed = Date().timeIntervalSince(workingSince ?? Date())
            if let notes, let baseline = notificationBaseline, notes.newestID > baseline {
                return finishInBackground(found: found, reason: "notification arrived → done", elapsed: elapsed)
            }
            if elapsed > backgroundLimit {
                return finishInBackground(found: found, reason: "gave up after 30 min", elapsed: 0)
            }
            if postsNotifications && notes != nil {
                quietBackgroundPolls = 0
                state = "working in background (waiting for its notification)"
                return PollResult(working: true, finished: false)
            }
            // No notifications to rely on: whole app (incl. helper processes) going quiet.
            let busy = Self.appCPU(cpu, appPath: appPath)
            quietBackgroundPolls = busy < 2.5 ? quietBackgroundPolls + 1 : 0
            if quietBackgroundPolls >= 15 {
                return finishInBackground(found: found, reason: "finished in background (app went quiet)",
                                          elapsed: elapsed)
            }
            state = String(format: "working in background (app CPU %.0f%%)", busy)
            return PollResult(working: true, finished: false)
        }
        quietBackgroundPolls = 0

        // Streaming text: the window's text keeps growing between polls.
        var streaming = false
        var textDelta = 0
        if watchText {
            if let length = AXSearch.visibleTextLength(in: app, pid: pid, nodeLimit: 20000, deadline: 1.5) {
                let grew = lastTextLength.map { length > $0 } ?? false
                textDelta = lastTextLength.map { length - $0 } ?? 0
                lastTextLength = length
                if grew { growCount += 1; quietCount = 0 } else { quietCount += 1; growCount = 0 }
                // Two growing polls in a row = a reply streaming in (your own sent message
                // adds text only once); three quiet polls = it stopped.
                if growCount >= 2 { textActive = true }
                if quietCount >= 3 { textActive = false }
            }
            streaming = textActive
        }

        // Response tracking: a new "Copy response" button = the reply is done.
        if !responsePatterns.isEmpty, let count = countResponseButtons() {
            if let previous = responseCount {
                if count == previous + 1 || count == previous + 2 {
                    responseCount = count
                    let wasActive = pending || working
                    pending = false; pendingSince = nil
                    working = false; missCount = 0
                    textActive = false; growCount = 0; quietCount = 0
                    state = "new response appeared → done"
                    return PollResult(working: false, finished: wasActive)
                } else if count != previous {
                    // Switched chats or loaded history: just re-baseline.
                    responseCount = count
                    pending = false; pendingSince = nil
                } else if !pending && textDelta > 0 && textDelta <= 6000 {
                    // The chat grew a little without a new response: you sent a message.
                    pending = true; pendingSince = Date()
                }
            } else {
                responseCount = count
            }
            if pending, let since = pendingSince, Date().timeIntervalSince(since) > pendingTimeout {
                pending = false; pendingSince = nil
            }
        }

        if found || streaming || pending {
            missCount = 0
            if !working { working = true; workingSince = Date() }
            state = found ? "Stop button visible → working"
                : streaming ? "reply text streaming → working"
                : "message sent, waiting for response → working"
            return PollResult(working: true, finished: false)
        }

        // Require two misses in a row so a re-render doesn't fake a "done".
        if working {
            missCount += 1
            if missCount >= 2 {
                working = false
                missCount = 0
                hotContainer = nil
                let duration = Date().timeIntervalSince(workingSince ?? Date())
                state = "idle (no Stop button)"
                return PollResult(working: false, finished: duration >= 1.5)
            }
            return PollResult(working: true, finished: false)
        }
        state = lastScan.windows == 0 ? "idle (no open window found)" : "idle (no Stop button)"
        return PollResult(working: false, finished: false)
    }

    private func findStopButton(app: AXUIElement) -> Bool {
        let now = Date()
        let fullScanDue = now.timeIntervalSince(lastFullScan) >= fullScanInterval

        // 1. Cheap: just the chat box (the area around Send/Stop), found by the last full
        //    scan. Most polls touch a few dozen elements instead of the whole window.
        if let composer = hotContainer, !fullScanDue {
            var stats = AXSearch.ScanStats()
            var ignored: [AXUIElement] = []
            let hit = AXSearch.walk(from: [composer], patterns: patterns, nodeLimit: 300, deadline: 0.3,
                                    webAreas: &ignored, stats: &stats)
            if let hit { lastMatch = hit.label; lastFound = true; return true }
            // Stop was there last time but isn't in the chat box now: confirm with a
            // full scan (it may have moved) before calling it done.
            if stats.buttons > 0 && !lastFound { return false }
            if stats.buttons == 0 { hotContainer = nil }   // chat box went away
        }

        // 2. Web content without a known chat box: ask the web areas for their buttons.
        if hotContainer == nil, !webAreas.isEmpty, !fullScanDue {
            var anyValid = false
            for area in webAreas {
                guard let buttons = AXSearch.buttonsInWebArea(area) else { continue }
                anyValid = true
                if let hit = AXSearch.firstMatch(in: buttons, patterns: patterns) {
                    hotContainer = AXSearch.ancestor(of: hit.element, levels: 3)
                    lastMatch = hit.label; lastFound = true
                    return true
                }
            }
            if anyValid && !lastFound { return false }
        }

        // 3. Full scan of the app's windows (every few seconds, or to confirm a change).
        var stats = AXSearch.ScanStats()
        var areas: [AXUIElement] = []
        let roots = AXSearch.windows(of: app, pid: pid)
        stats.windows = roots.count
        let hit = AXSearch.walk(from: roots, patterns: patterns, nodeLimit: 40000, deadline: 1.5,
                                webAreas: &areas, stats: &stats)
        lastScan = stats
        webAreas = areas
        lastFullScan = now
        hotContainer = stats.composer
        if let hit { lastMatch = hit.label }
        lastFound = hit != nil
        return lastFound
    }

    private func finishInBackground(found: Bool, reason: String, elapsed: TimeInterval) -> PollResult {
        quietBackgroundPolls = 0
        staleButton = found
        working = false
        missCount = 0
        hotContainer = nil
        textActive = false; growCount = 0; quietCount = 0; lastTextLength = nil
        // Re-baseline response tracking so returning to the app doesn't flash again.
        pending = false; pendingSince = nil; responseCount = nil
        notificationBaseline = nil
        state = reason
        return PollResult(working: false, finished: elapsed >= 1.5)
    }

    /// CPU percent of all the app's processes (main app plus helpers).
    static func appCPU(_ cpu: [String: Double], appPath: String) -> Double {
        let prefix = appPath + "/"
        return cpu.reduce(0) { $1.key.hasPrefix(prefix) ? $0 + $1.value : $0 }
    }

    /// CPU percent of the app's window (renderer) processes, or of the whole app if it has none.
    static func windowCPU(_ cpu: [String: Double], appPath: String) -> Double {
        let prefix = appPath + "/"
        var all = 0.0, renderers = 0.0, hasRenderer = false
        for (path, pct) in cpu where path.hasPrefix(prefix) {
            all += pct
            if path.contains("(Renderer)") { hasRenderer = true; renderers += pct }
        }
        return hasRenderer ? renderers : all
    }

    /// How many response buttons ("Copy response") the app's web content shows right now.
    private func countResponseButtons() -> Int? {
        guard !webAreas.isEmpty else { return nil }
        var total = 0
        var anyValid = false
        for area in webAreas {
            guard let buttons = AXSearch.buttonsInWebArea(area) else { continue }
            anyValid = true
            for b in buttons {
                let labels = AXSearch.node(b)?.labels ?? []
                if labels.contains(where: { l in responsePatterns.contains(l.lowercased()) }) { total += 1 }
            }
        }
        return anyValid ? total : nil
    }

    private func reset() {
        responseCount = nil; pending = false; pendingSince = nil
        staleButton = false; frontFoundPolls = 0; quietBackgroundPolls = 0
        pid = nil; appElement = nil; hotContainer = nil; webAreas = []
        lastFullScan = .distantPast; lastFound = false
        wasFrontmost = false; notificationBaseline = nil
        working = false; missCount = 0
        lastTextLength = nil; growCount = 0; quietCount = 0; textActive = false
    }

    /// The running app's AX element, (re)created when the process changes.
    private func currentAppElement() -> AXUIElement? {
        guard let running = AXSearch.runningApp(atPath: appPath) else { return nil }
        let p = running.processIdentifier
        if p != pid || appElement == nil {
            reset()
            pid = p
            bundleID = running.bundleIdentifier
            let el = AXUIElementCreateApplication(p)
            AXUIElementSetMessagingTimeout(el, 1.0)
            AXSearch.enableWebAccessibility(el)
            appElement = el
        }
        return appElement
    }

    var diagnostics: String {
        // Built step by step: one big expression is too slow for the Swift type checker.
        var lines: [String] = []
        let pidText: String = pid.map { String($0) } ?? "none"
        let textReading: String = lastTextLength.map { String($0) } ?? "scan didn't finish"
        let textStatus: String = watchText ? "on (last reading: \(textReading))" : "off"
        let fallbackStatus: String = backgroundFallback ? "on" : "off"

        var responseStatus: String = "off"
        if !responsePatterns.isEmpty {
            let countText: String = responseCount.map { String($0) } ?? "?"
            let waiting: String = pending ? ", waiting for response" : ""
            let labels: String = responsePatterns.joined(separator: ", ")
            responseStatus = "\(labels) (count: \(countText)\(waiting))"
        }

        lines.append("  app: \(appPath)")
        lines.append("  running pid: \(pidText)")
        lines.append("  state: \(state)")
        lines.append("  stop labels: \(patterns.joined(separator: ", "))")
        lines.append("  last full scan: \(lastScan.summary)")
        lines.append("  web areas: \(webAreas.count)")
        lines.append("  watch streaming text: \(textStatus)")
        lines.append("  background done fallback: \(fallbackStatus)")
        lines.append("  response buttons: \(responseStatus)")
        let noteStatus: String = bundleID == nil ? "unknown app"
            : (postsNotifications ? "yes (used as the background done signal)" : "none on record")
        lines.append("  posts notifications: \(noteStatus)")
        if let err = NotificationWatcher.shared.lastError { lines.append("  notification database: \(err)") }
        if let lastMatch { lines.append("  last matched button: \(lastMatch)") }
        if !lastScan.sampleButtons.isEmpty {
            lines.append("  buttons seen in last scan:")
            for button in lastScan.sampleButtons { lines.append("    - \(button)") }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Accessibility helpers

enum AXSearch {
    struct ScanStats {
        var windows = 0
        var nodes = 0
        var buttons = 0
        var seconds: Double = 0
        var complete = false
        var predicateUsed = false
        var sampleButtons: [String] = []
        /// The area around the Send/Stop button (the chat box), if one was seen.
        var composer: AXUIElement?

        var summary: String {
            let status = complete ? "complete" : "INCOMPLETE (hit time/size limit)"
            return String(format: "%d window(s), %d elements, %d buttons, %.2fs, ", windows, nodes, buttons, seconds)
                + status + (predicateUsed ? ", used web-area search" : "")
        }
    }

    struct Node {
        var role: String?
        var labels: [String]
        var children: [AXUIElement]
    }

    static let nodeAttributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                 kAXHelpAttribute, "AXIdentifier", kAXChildrenAttribute] as CFArray

    /// Electron/Chromium apps (Claude, etc.) only build their accessibility tree when asked.
    static func enableWebAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    static func runningApp(atPath path: String) -> NSRunningApplication? {
        let prefix = path + "/"
        return NSWorkspace.shared.runningApplications.first { app in
            if let b = app.bundleURL?.path, b == path || b.hasPrefix(prefix) { return true }
            if let e = app.executableURL?.path, e.hasPrefix(prefix) { return true }
            return false
        }
    }

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attribute(el, name) as? String
    }

    /// Role, labels and children in a single round-trip.
    static func node(_ el: AXUIElement) -> Node? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, nodeAttributes, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let arr = values as? [AnyObject], arr.count == 6 else { return nil }
        // Missing attributes come back as AXValue error placeholders; the casts skip them.
        let labels = arr[1...4].compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Node(role: arr[0] as? String, labels: labels, children: (arr[5] as? [AXUIElement]) ?? [])
    }

    /// The app's windows. With a pid, this also finds windows on other desktops and
    /// full-screen spaces (see OtherSpaceWindows), which the public API leaves out.
    static func windows(of app: AXUIElement, pid: pid_t? = nil) -> [AXUIElement] {
        let visible = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let pid else { return visible }
        return OtherSpaceWindows.shared.windows(pid: pid, visible: visible)
    }

    static func isButtonRole(_ role: String?) -> Bool {
        role == kAXButtonRole || role == "AXMenuButton" || role == "AXPopUpButton"
    }

    /// Words that mean a "stop" control is about something other than the reply
    /// (dictation, voice mode, recording, sharing...).
    private static let notAReply = ["dictat", "record", "listen", "voice", "read aloud", "speak",
                                    "audio", "video", "share", "sharing", "screen"]

    /// Each line of a label that's short enough to be a control (chat titles and
    /// message text are longer), lowercased.
    private static func controlLines(_ label: String) -> [String] {
        label.lowercased()
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.split(separator: " ").count <= 4 }
    }

    /// Is this the label of a "stop the reply" button?
    ///  - Your own `stopButtons` from the config: a single word must match exactly, a
    ///    phrase may appear anywhere.
    ///  - Built in: short labels starting with "stop", "cancel generat…", "cancel response"
    ///    or "interrupt", and hidden identifiers like "stop-button" / "composer_stop",
    ///    unless they're about dictation, voice, recording or sharing.
    static func matches(_ label: String, _ patterns: [String]) -> Bool {
        let whole = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if patterns.contains(where: { p in whole == p || (p.contains(" ") && whole.contains(p)) }) {
            return true
        }
        guard !patterns.isEmpty else { return false }   // label dump (Show Button Names) matches nothing
        return controlLines(label).contains { line in
            if notAReply.contains(where: { line.contains($0) }) { return false }
            let words = line.split(separator: " ")
            let stopPrefixes = ["stop ", "cancel generat", "cancel response", "interrupt"]
            if words.count <= 3, line == "stop" || stopPrefixes.contains(where: { line.hasPrefix($0) }) {
                return true
            }
            // Identifier-style names: a single token with "stop" as one of its parts.
            if words.count == 1 {
                let parts = line.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
                return parts.count > 1 && parts.contains("stop")
            }
            return false
        }
    }

    /// The button you press to send a prompt; its surroundings are the chat box.
    static func isSendLabel(_ label: String) -> Bool {
        controlLines(label).contains { line in
            line == "send" || line.hasPrefix("send ") || line == "submit" || line.hasPrefix("submit ")
                || line.hasSuffix("send-button") || line.hasSuffix("send_button")
        }
    }

    private static func describe(_ labels: [String]) -> String {
        labels.isEmpty ? "(unlabeled)" : labels.joined(separator: " | ")
    }

    /// Breadth-first walk looking for a matching button. Web areas are not walked
    /// element by element: their buttons come from the fast predicate search, and the
    /// web areas are collected into `webAreas` for later polls.
    static func walk(from roots: [AXUIElement], patterns: [String], nodeLimit: Int, deadline: TimeInterval,
                     webAreas: inout [AXUIElement], stats: inout ScanStats)
        -> (element: AXUIElement, label: String)? {
        let start = Date()
        defer { stats.seconds = Date().timeIntervalSince(start) }
        var queue = roots
        var index = 0
        while index < queue.count {
            if index >= nodeLimit || (index % 25 == 0 && Date().timeIntervalSince(start) > deadline) {
                stats.complete = false
                return nil
            }
            let el = queue[index]
            index += 1
            stats.nodes += 1
            guard let n = node(el) else { continue }

            if isButtonRole(n.role) {
                stats.buttons += 1
                if stats.sampleButtons.count < 40 { stats.sampleButtons.append(describe(n.labels)) }
                if stats.composer == nil, n.labels.contains(where: isSendLabel) {
                    stats.composer = ancestor(of: el, levels: 3)
                }
                if let label = n.labels.first(where: { matches($0, patterns) }) {
                    if stats.composer == nil { stats.composer = ancestor(of: el, levels: 3) }
                    return (el, label)
                }
            }

            if n.role == "AXWebArea", let buttons = buttonsInWebArea(el) {
                stats.predicateUsed = true
                webAreas.append(el)
                for b in buttons {
                    stats.buttons += 1
                    let labels = node(b)?.labels ?? []
                    if stats.sampleButtons.count < 40 { stats.sampleButtons.append(describe(labels)) }
                    if stats.composer == nil, labels.contains(where: isSendLabel) {
                        stats.composer = ancestor(of: b, levels: 3)
                    }
                    if let label = labels.first(where: { matches($0, patterns) }) {
                        if stats.composer == nil { stats.composer = ancestor(of: b, levels: 3) }
                        return (b, label)
                    }
                }
                continue   // its buttons are covered; don't walk thousands of web elements
            }
            queue.append(contentsOf: n.children)
        }
        stats.complete = true
        return nil
    }

    /// All buttons inside a web area, using the search VoiceOver uses. nil if unsupported
    /// or the element is gone.
    static func buttonsInWebArea(_ area: AXUIElement) -> [AXUIElement]? {
        search(area, key: "AXButtonSearchKey", limit: 1000)
    }

    static func firstMatch(in buttons: [AXUIElement], patterns: [String]) -> (element: AXUIElement, label: String)? {
        for b in buttons {
            if let label = node(b)?.labels.first(where: { matches($0, patterns) }) { return (b, label) }
        }
        return nil
    }

    /// A number that grows while reply text streams into the app's windows (message
    /// bubbles, not the box you type in). nil if the scan couldn't finish in time, so a
    /// partial scan never looks like text changing.
    ///
    /// Native parts of the window are walked; web areas (Electron/Chromium apps) are asked
    /// for their static text directly, and only the last few text runs are measured.
    static func visibleTextLength(in app: AXUIElement, pid: pid_t? = nil, nodeLimit: Int,
                                  deadline: TimeInterval) -> Int? {
        let attrs = [kAXRoleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
        let start = Date()
        var queue = windows(of: app, pid: pid)
        guard !queue.isEmpty else { return nil }
        var index = 0
        var total = 0
        while index < queue.count {
            if index >= nodeLimit || (index % 25 == 0 && Date().timeIntervalSince(start) > deadline) {
                return nil
            }
            let el = queue[index]
            index += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                         &values) == .success,
                  let arr = values as? [AnyObject], arr.count == 4 else { continue }
            let role = arr[0] as? String
            if role == kAXStaticTextRole {
                total += ((arr[1] as? String)?.count ?? 0) + ((arr[2] as? String)?.count ?? 0)
                continue   // static text has no interesting children
            }
            if role == "AXWebArea", let texts = search(el, key: "AXStaticTextSearchKey", limit: 20000) {
                // Count of text runs + length of the newest ones: both grow while a reply streams.
                total += texts.count * 1000
                for t in texts.suffix(30) {
                    total += (string(t, kAXValueAttribute)?.count ?? 0)
                }
                continue
            }
            queue.append(contentsOf: (arr[3] as? [AXUIElement]) ?? [])
        }
        return total
    }

    /// The accessibility search VoiceOver uses, inside a web area. nil if unsupported.
    static func search(_ area: AXUIElement, key: String, limit: Int) -> [AXUIElement]? {
        let params: [String: Any] = [
            "AXSearchKey": key,
            "AXResultsLimit": limit,
            "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false,
            "AXVisibleOnly": false,
        ]
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            area, "AXUIElementsForSearchPredicate" as CFString, params as CFDictionary, &result)
        guard err == .success else { return nil }
        return result as? [AXUIElement]
    }

    static func ancestor(of el: AXUIElement, levels: Int) -> AXUIElement? {
        var current = el
        for _ in 0..<levels {
            guard let parent = attribute(current, kAXParentAttribute) else { break }
            current = parent as! AXUIElement  // CF type: the cast always succeeds
        }
        return current
    }

    /// Every button label in the app (for tuning `stopButtons`). The first line
    /// summarizes the scan.
    static func allButtonLabels(appPath: String) -> [String]? {
        guard let running = runningApp(atPath: appPath) else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        enableWebAccessibility(app)
        var stats = ScanStats()
        var areas: [AXUIElement] = []
        let roots = windows(of: app, pid: running.processIdentifier)
        stats.windows = roots.count
        _ = walk(from: roots, patterns: [], nodeLimit: 60000, deadline: 8, webAreas: &areas, stats: &stats)
        var out = stats.sampleButtons
        // sampleButtons is capped at 40; add the rest of the web buttons directly.
        for area in areas {
            for b in buttonsInWebArea(area) ?? [] {
                out.append(describe(node(b)?.labels ?? []))
            }
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0).inserted }
        out.insert("[scan: \(stats.summary)]", at: 0)
        return out
    }
}
