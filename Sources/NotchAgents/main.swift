import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()
    private var lastConfigDate: Date?
    private var watchTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.contextMenuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        reloadConfig(showErrors: true)

        // Re-layout when displays change (lid open/close, external monitor, resolution).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.controller.layout() }

        // Instinct's status needs Full Disk Access; say so once rather than failing silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.controller.needsFullDiskAccess else { return }
            let key = "lastFullDiskAccessPrompt"
            let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
            guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
            UserDefaults.standard.set(Date(), forKey: key)
            self.openFullDiskAccess()
        }

        // Pick up config edits automatically.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let date = ConfigStore.modificationDate()
            if date != self.lastConfigDate { self.reloadConfig(showErrors: true) }
        }
    }

    private func reloadConfig(showErrors: Bool) {
        let (config, error) = ConfigStore.load()
        lastConfigDate = ConfigStore.modificationDate()
        controller.apply(config)
        if let error, showErrors {
            Launcher.showError("Notch Agents config has an error", detail: error)
        }
    }

    // MARK: - Right-click menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Edit Agents…", #selector(editConfig)))
        menu.addItem(item("Reload", #selector(reload)))
        menu.addItem(item("Show Config in Finder", #selector(revealConfig)))
        let readings = controller.activityReadings
        if !readings.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Activity (live)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in readings {
                let row = NSMenuItem(title: "\(r.name): \(r.text)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
        }
        if controller.needsAccessibility {
            menu.addItem(.separator())
            menu.addItem(item("Allow App Status (Accessibility)…", #selector(openAccessibility)))
        }
        if controller.needsAccessibility || controller.needsFullDiskAccess {
            menu.addItem(item("Fix Permissions (switch is on but not working)…", #selector(resetPermissions)))
        }
        menu.addItem(item("Copy Diagnostics", #selector(copyDiagnostics)))
        let buttonApps = controller.buttonApps
        if !buttonApps.isEmpty {
            let sub = NSMenu()
            for app in buttonApps {
                let entry = item(app.name, #selector(showButtonNames(_:)))
                entry.representedObject = app.path
                sub.addItem(entry)
            }
            let parent = NSMenuItem(title: "Show Button Names", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        if controller.needsFullDiskAccess {
            menu.addItem(.separator())
            menu.addItem(item("Allow Instinct Status (Full Disk Access)…", #selector(openFullDiskAccess)))
        }
        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Notch Agents", #selector(quit)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func editConfig() { ConfigStore.openInEditor() }
    @objc private func reload() { reloadConfig(showErrors: true) }
    @objc private func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL]) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Instinct's working/done status comes from the Messages database, which macOS
    /// only lets apps read with Full Disk Access.
    @objc private func openFullDiskAccess() {
        let alert = NSAlert()
        alert.messageText = "Let Notch Agents see when Instinct replies"
        alert.informativeText = "In the window that opens, turn on NotchAgents under Full Disk Access " +
            "(use + to add /Applications/NotchAgents.app if it isn't listed), then quit and reopen Notch Agents.\n\n" +
            "It only reads whether the last message in your Instinct chat is from you or from Instinct."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Claude/Gemini/Muse status comes from reading their Stop button, which needs Accessibility.
    @objc private func openAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Let Notch Agents see when your AI apps are answering"
        alert.informativeText = "In the window that opens, turn on NotchAgents under Accessibility " +
            "(use + to add /Applications/NotchAgents.app if it isn't listed).\n\n" +
            "It only checks whether Claude, Gemini or Muse is showing a Stop button. " +
            "After rebuilding the app you may need to switch it off and on again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Lists every button the app exposes, so the right "stopButtons" label can be found.
    /// Best used while the app is in the middle of answering.
    @objc private func showButtonNames(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let name = sender.title
        DispatchQueue.global(qos: .userInitiated).async {
            let labels = AXSearch.allButtonLabels(appPath: path)
            DispatchQueue.main.async {
                guard AXIsProcessTrusted() else { self.openAccessibility(); return }
                guard let labels else {
                    Launcher.showError("\(name) isn't running", detail: "Open it, start a prompt, then try again.")
                    return
                }
                let text = "Buttons currently shown by \(name) (\(path))\n" +
                    "Tip: run this while \(name) is answering, then put the stop button's label in " +
                    "\"stopButtons\" for \(name) in \(ConfigStore.fileURL.path)\n\n" +
                    (labels.isEmpty ? "(no buttons found)" : labels.joined(separator: "\n"))
                let file = ConfigStore.directory.appendingPathComponent("buttons-\(name.lowercased()).txt")
                try? text.write(to: file, atomically: true, encoding: .utf8)
                let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
                NSWorkspace.shared.open([file], withApplicationAt: textEdit,
                                        configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
    }

    /// When a permission switch shows "on" but macOS still refuses, the switch belongs to an
    /// older build with a different signature. Clear NotchAgents' entries and relaunch so
    /// macOS asks again for this build.
    @objc private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = "Reset Notch Agents' permissions?"
        alert.informativeText = "This clears NotchAgents' Accessibility and Full Disk Access entries " +
            "(only for this app) and reopens it.\n\n" +
            "• macOS will ask for Accessibility again: click Open System Settings and switch NotchAgents on.\n" +
            "• For Instinct, add NotchAgents under Full Disk Access with + and switch it on.\n\n" +
            "Then quit and reopen Notch Agents once more."
        alert.addButton(withTitle: "Reset and Reopen")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let id = Bundle.main.bundleIdentifier ?? "com.kourakis.notchagents"
        for service in ["Accessibility", "SystemPolicyAllFiles"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", service, id]
            try? task.run()
            task.waitUntilExit()
        }
        UserDefaults.standard.removeObject(forKey: "lastFullDiskAccessPrompt")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
        // Relaunch so the new process asks for Accessibility from scratch.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// Copies a troubleshooting report to the clipboard (and saves it next to the config).
    @objc private func copyDiagnostics() {
        let bundle = Bundle.main.bundlePath
        DispatchQueue.global(qos: .userInitiated).async {
            let body = self.controller.activityDiagnostics()
            let report = """
                Notch Agents diagnostics — \(Date())
                App: \(bundle)
                macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)

                \(body)
                """
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                let file = ConfigStore.directory.appendingPathComponent("diagnostics.txt")
                try? report.write(to: file, atomically: true, encoding: .utf8)
                let alert = NSAlert()
                alert.messageText = "Diagnostics copied"
                alert.informativeText = "Paste them into your chat with Claude. Tip: copy them while an app is in the " +
                    "middle of answering. (Also saved to \(file.path).)"
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Launcher.showError("Couldn't change Open at Login",
                               detail: "Make sure you're running NotchAgents.app (not the raw binary).\n\(error.localizedDescription)")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, even when run outside the .app bundle
app.run()
