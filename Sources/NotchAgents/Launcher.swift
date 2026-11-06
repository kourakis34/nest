import AppKit

enum Launcher {
    static func run(_ agent: AgentConfig) {
        let action = agent.action
        let ok: Bool
        switch action.type.lowercased() {
        case "app":
            ok = openApp(action)
        case "imessage", "messages":
            ok = openIMessage(action.handle)
        case "url":
            ok = openURLString(action.url)
        case "shell":
            ok = runShell(action.command)
        default:
            ok = false
        }

        if !ok {
            if let fallback = action.fallbackURL, openURLString(fallback) { return }
            var detail = "Check its entry in \(ConfigStore.fileURL.path)"
            if action.type.lowercased() == "app" {
                let names = ([action.appName].compactMap { $0 } + (action.alternateNames ?? []))
                    .map { "\"\($0)\"" }.joined(separator: ", ")
                detail = "No installed app matched \(names).\n\nOpen Finder → Applications, find the app's exact name, " +
                         "and put it in \"appName\" in \(ConfigStore.fileURL.path)"
            }
            showError("Couldn't find the app for \(agent.name)", detail: detail)
        }
    }

    // MARK: - Resolution helpers (also used for icons)

    private static var lookupCache: [String: URL] = [:]

    static func appURL(for action: AgentAction) -> URL? {
        let ws = NSWorkspace.shared
        if let id = action.bundleId, let url = ws.urlForApplication(withBundleIdentifier: id) {
            return url
        }
        if let path = action.appPath {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        let names = ([action.appName] + (action.alternateNames ?? []).map { Optional($0) })
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        guard !names.isEmpty else { return nil }

        let key = names.joined(separator: "|")
        if let cached = lookupCache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let found = findApp(named: names)
        if let found { lookupCache[key] = found }
        return found
    }

    /// Looks for an installed app by name: exact names in the usual folders first,
    /// then a Spotlight search that also catches App Store / iPhone-iPad apps and
    /// apps whose name only contains the given text (e.g. "Meta AI" → "Meta AI Assistant").
    private static func findApp(named names: [String]) -> URL? {
        let fm = FileManager.default
        let folders = ["/Applications", "/System/Applications", "\(NSHomeDirectory())/Applications",
                       "/Applications/Utilities", "/System/Applications/Utilities"]

        // 1. Exact name in a standard folder.
        for name in names {
            for folder in folders {
                let path = "\(folder)/\(name).app"
                if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }

        // 2. Case-insensitive / partial match in the standard folders (main name only,
        //    so a short alternate like "Muse" can't grab an unrelated app like "MuseScore").
        for name in names.prefix(1) {
            let needle = name.lowercased()
            for folder in folders {
                guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
                if let hit = items.first(where: { $0.hasSuffix(".app") && $0.lowercased().contains(needle) }) {
                    return URL(fileURLWithPath: "\(folder)/\(hit)")
                }
            }
        }

        // 3. Spotlight, anywhere on the Mac.
        for (i, name) in names.enumerated() {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "'", with: "\\'")
            let pattern = i == 0 ? "*\(escaped)*" : escaped          // partial match for the main name only
            let query = "kMDItemContentType == 'com.apple.application-bundle' && " +
                        "(kMDItemDisplayName == '\(pattern)'cd || kMDItemFSName == '\(pattern).app'cd)"
            if let path = mdfind(query).first { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    private static func mdfind(_ query: String) -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = [query]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasSuffix(".app") && !$0.contains("/Library/") }
            .sorted { $0.count < $1.count }   // prefer the shortest (top-level) match
    }

    static var messagesAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS")
    }

    // MARK: - Actions

    private static func openApp(_ action: AgentAction) -> Bool {
        guard let url = appURL(for: action) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                DispatchQueue.main.async { showError("Couldn't launch \(url.lastPathComponent)", detail: "\(error.localizedDescription)") }
            }
        }
        return true
    }

    private static func openIMessage(_ handle: String?) -> Bool {
        guard let raw = handle?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              !raw.hasPrefix("REPLACE_") else {
            showError("Instinct's iMessage contact isn't set",
                      detail: "Put the phone number or email in the \"handle\" field in \(ConfigStore.fileURL.path)")
            return true // already reported; don't also show the generic error
        }
        // Phone numbers: strip formatting. Emails/Apple IDs: keep as-is.
        let cleaned = raw.contains("@")
            ? raw
            : raw.filter { $0.isNumber || $0 == "+" }
        guard let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed),
              let url = URL(string: "imessage://\(encoded)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func openURLString(_ string: String?) -> Bool {
        guard let string, let url = URL(string: string) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func runShell(_ command: String?) -> Bool {
        guard let command, !command.isEmpty else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        do { try task.run(); return true } catch { return false }
    }

    static func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Edit Config")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            ConfigStore.openInEditor()
        }
    }
}
