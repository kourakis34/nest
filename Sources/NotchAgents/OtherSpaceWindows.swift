import ApplicationServices
import Foundation

// Undocumented AX function (part of the system's HIServices framework). It builds an
// accessibility element from a "remote token": the owning pid plus an element ID.
// Window switchers use it to reach windows on other Spaces, which the public
// kAXWindowsAttribute doesn't list. If a future macOS removes or changes it, this
// file just stops finding extra windows; nothing else depends on it.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func axElementFromRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Finds an app's windows on every desktop (Space), including full-screen ones.
///
/// The public API only returns windows on the desktop you're looking at, so an app
/// that's full screen or on another desktop looks window-less. When that happens we
/// probe the app's first element IDs for windows. That's ~1,000 quick calls, so it's
/// done at most every 30 seconds per app, and found windows are remembered (their
/// handles keep working after you switch desktops).
final class OtherSpaceWindows {
    static let shared = OtherSpaceWindows()

    private struct Entry { var windows: [AXUIElement]; var probedAt: Date }
    private var entries: [pid_t: Entry] = [:]
    private let lock = NSLock()
    private let probeInterval: TimeInterval = 30
    private let maxElementID: UInt64 = 1000
    /// "coco": the tag the system uses for these tokens.
    private let tokenTag: Int32 = 0x636F_636F

    /// `visible`: windows the public API returned. Returns those plus any remembered or
    /// newly probed windows from other desktops, keeping only real, still-open windows.
    func windows(pid: pid_t, visible: [AXUIElement]) -> [AXUIElement] {
        lock.lock(); defer { lock.unlock() }

        var entry = entries[pid] ?? Entry(windows: [], probedAt: .distantPast)
        if visible.isEmpty && Date().timeIntervalSince(entry.probedAt) >= probeInterval {
            entry.windows = probe(pid: pid)
            entry.probedAt = Date()
        }

        var result = visible
        for w in entry.windows where !result.contains(where: { CFEqual($0, w) }) {
            result.append(w)
        }
        result = result.filter(isOpenAppWindow)
        entry.windows = result
        entries[pid] = entry
        entries = entries.filter { kill($0.key, 0) == 0 }   // forget apps that quit
        return result
    }

    private func probe(pid: pid_t) -> [AXUIElement] {
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: tokenTag, toByteOffset: 8, as: Int32.self)
        }
        var found: [AXUIElement] = []
        for id in 0..<maxElementID {
            token.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: id, toByteOffset: 12, as: UInt64.self)
            }
            guard let element = axElementFromRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.1)
            if AXSearch.string(element, kAXRoleAttribute) == kAXWindowRole {
                found.append(element)
            }
        }
        return found
    }

    /// A standard window or dialog that still exists (closed windows stop answering).
    private func isOpenAppWindow(_ element: AXUIElement) -> Bool {
        guard AXSearch.string(element, kAXRoleAttribute) == kAXWindowRole else { return false }
        guard let subrole = AXSearch.string(element, kAXSubroleAttribute) else { return true }
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }
}
