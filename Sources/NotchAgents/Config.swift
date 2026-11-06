import AppKit

/// What happens when an agent icon is clicked.
struct AgentAction: Codable, Equatable {
    /// One of: "app", "imessage", "url", "shell"
    var type: String

    // type == "app": give a bundleId, an appName, or an appPath (first match wins).
    var bundleId: String?
    var appName: String?
    var appPath: String?

    // type == "imessage": phone number or Apple ID email of the conversation to open.
    var handle: String?

    // type == "url": any URL (https://, custom schemes, etc.)
    var url: String?

    // type == "shell": a command run with /bin/zsh -lc
    var command: String?

    /// Optional URL opened if the primary action fails (e.g. app not installed).
    var fallbackURL: String?

    /// type == "app": other names the app might be installed under. Matching is
    /// case-insensitive and also finds apps whose name merely contains one of these.
    var alternateNames: [String]?
}

struct AgentConfig: Codable, Equatable {
    var name: String
    /// Icon source. Options:
    ///  - omitted: use ~/.config/notch-agents/icons/<name>.png if it exists,
    ///    otherwise the target app's own icon (or Messages' icon for imessage)
    ///  - "builtin:instinct": the Instinct "I" badge
    ///  - "builtin:robot": a neutral robot head
    ///  - "sf:<symbol name>": an SF Symbol, e.g. "sf:bolt.fill"
    ///  - "app:<bundle id>": borrow another app's icon
    ///  - an absolute path (~ allowed) to a .png / .icns / .jpg
    var icon: String?
    var action: AgentAction
    /// Neon outline color while this agent is working: "#RRGGBB" or "rainbow".
    /// Omitted: Instinct white, Muse blue, Claude orange, Gemini rainbow, others white.
    var glow: String?
    /// How to tell this agent is working on a prompt:
    ///  - "auto" (default): "imessage" for iMessage agents, "buttons" for apps
    ///  - "buttons": the app is showing a Stop button (needs Accessibility permission)
    ///  - "imessage": you sent the last message and no reply has arrived yet
    ///  - "cpu": the app's window is busy (CPU at least `cpuThreshold` points above its idle level)
    ///  - "none": never show an outline for this agent
    var activity: String?
    /// For "cpu" activity: how many CPU percentage points above the app's own idle level
    /// count as working (default 8).
    var cpuThreshold: Double?
    /// For "buttons" activity: labels of the app's stop button. A single word must match
    /// a button label exactly; a phrase may appear anywhere in it. Case-insensitive.
    /// Default: "stop", "stop response", "stop generating", "stop streaming", ...
    var stopButtons: [String]?
    /// For "buttons" activity: also count reply text streaming into the window as working.
    /// Default: on for Muse (its stop button may have no label), off for others.
    var watchText: Bool?

    var resolvedWatchText: Bool { watchText ?? (name.lowercased() == "muse") }

    /// For "buttons" activity: while the app is in the background, also count its window
    /// going quiet as "done" (web-based apps stop updating their Stop button in the
    /// background). Default: on for Claude and Muse.
    var backgroundDone: Bool?

    /// For "buttons" activity: label of the button each finished reply gets (exact,
    /// case-insensitive). A new one appearing = done; sending a message = working.
    /// Default: ["Copy response"] for Muse (it has no labeled Stop button), none for others.
    var responseButtons: [String]?

    var resolvedResponseButtons: [String] {
        responseButtons ?? (name.lowercased() == "muse" ? ["Copy response"] : [])
    }

    var resolvedBackgroundDone: Bool { backgroundDone ?? ["claude", "muse"].contains(name.lowercased()) }

    /// The glow spec to use, falling back to per-agent defaults.
    var resolvedGlow: String {
        if let glow, !glow.isEmpty { return glow }
        switch name.lowercased() {
        case "instinct": return "#FFFFFF"
        case "muse": return "#2F7BFF"
        case "claude": return "#FF7A2F"
        case "gemini": return "rainbow"
        default: return "#FFFFFF"
        }
    }

    var resolvedActivity: String {
        let a = (activity ?? "auto").lowercased()
        guard a == "auto" else { return a }
        switch action.type.lowercased() {
        case "imessage", "messages": return "imessage"
        case "app": return "buttons"
        default: return "none"
        }
    }
}

struct AppConfig: Codable, Equatable {
    /// "hover": icons drop down from the notch when the mouse is over it (default).
    /// "wings": icons always visible to the left and right of the notch.
    var mode: String = "hover"
    /// Icon size in points. 0 = automatic (fits the menu bar in "wings", 32 in "hover").
    var iconSize: Double = 0
    /// Space between icons.
    var spacing: Double = 8
    /// Gap between the notch edge and the nearest icon.
    var notchPadding: Double = 8
    /// Paint a black strip behind the icons so the notch looks like it grew "wings".
    var extendNotch: Bool = true
    /// Show a neon outline around the notch while agents are working.
    var showActivity: Bool = true
    /// Color of the flash when an agent finishes.
    var doneColor: String = "#39FF14"
    /// Agents shown left of the camera, ordered left → right.
    var left: [AgentConfig]
    /// Agents shown right of the camera, ordered left → right.
    var right: [AgentConfig]

    static let `default` = AppConfig(
        left: [
            AgentConfig(
                name: "Instinct",
                icon: "builtin:instinct",
                action: AgentAction(type: "imessage", handle: "REPLACE_WITH_INSTINCT_NUMBER_OR_EMAIL")
            ),
            AgentConfig(
                name: "Muse",
                icon: nil, // ~/.config/notch-agents/icons/muse.png if present, else the Muse app's own icon
                action: AgentAction(type: "app", appName: "Meta AI",
                                    alternateNames: ["Muse"])
            ),
        ],
        right: [
            AgentConfig(
                name: "Claude",
                icon: nil,
                action: AgentAction(type: "app", bundleId: "com.anthropic.claudefordesktop",
                                    appName: "Claude", fallbackURL: "https://claude.ai")
            ),
            AgentConfig(
                name: "Gemini",
                icon: nil,
                action: AgentAction(type: "app", appName: "Gemini",
                                    fallbackURL: "https://gemini.google.com")
            ),
        ]
    )
}

// Lenient decoding so a hand-edited config with missing layout keys still loads.
extension AppConfig {
    enum CodingKeys: String, CodingKey { case mode, iconSize, spacing, notchPadding, extendNotch, showActivity, doneColor, left, right }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "hover"
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? 0
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 8
        notchPadding = try c.decodeIfPresent(Double.self, forKey: .notchPadding) ?? 8
        extendNotch = try c.decodeIfPresent(Bool.self, forKey: .extendNotch) ?? true
        showActivity = try c.decodeIfPresent(Bool.self, forKey: .showActivity) ?? true
        doneColor = try c.decodeIfPresent(String.self, forKey: .doneColor) ?? "#39FF14"
        left = try c.decodeIfPresent([AgentConfig].self, forKey: .left) ?? []
        right = try c.decodeIfPresent([AgentConfig].self, forKey: .right) ?? []
    }
}

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/notch-agents", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Loads the config, writing the defaults on first run.
    /// Returns the config plus an error message if the file couldn't be parsed.
    static func load() -> (AppConfig, String?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            writeDefault()
            return (.default, nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            var config = try JSONDecoder().decode(AppConfig.self, from: data)
            if migrate(&config) { save(config) }
            return (config, nil)
        } catch {
            return (.default, "Couldn't read \(fileURL.path):\n\(error)")
        }
    }

    /// One-time upgrades for configs written by earlier versions.
    private static func migrate(_ config: inout AppConfig) -> Bool {
        var changed = false
        for i in config.left.indices where config.left[i].name == "Instinct"
            && (config.left[i].icon == "sf:bolt.fill" || config.left[i].icon == "builtin:robot") {
            config.left[i].icon = "builtin:instinct"; changed = true
        }
        // Early builds pointed Muse at an app literally named "Muse" (or at meta.ai as a fallback).
        let museDefault = AppConfig.default.left.first { $0.name == "Muse" }!
        for i in config.left.indices where config.left[i].name == "Muse" {
            if config.left[i].icon == "sf:sparkles" { config.left[i].icon = nil; changed = true }
            let a = config.left[i].action
            if a.type == "app", a.bundleId == nil, a.appPath == nil, a.alternateNames == nil,
               a.appName == "Muse" || a.appName == "Meta AI" {
                config.left[i].action = museDefault.action; changed = true
            }
        }
        return changed
    }

    static var iconsDirectory: URL { directory.appendingPathComponent("icons", isDirectory: true) }

    static func save(_ config: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NotchAgents: failed to write config: \(error)")
        }
    }

    /// Opens the config file in TextEdit (plain text).
    static func openInEditor() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { writeDefault() }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([fileURL], withApplicationAt: textEdit,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    static func writeDefault() { save(.default) }
}
