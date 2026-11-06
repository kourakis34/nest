import AppKit
import Darwin

/// Measures CPU use of the tracked apps and their helper processes by asking the
/// kernel directly (libproc), instead of launching `ps` every second.
///
/// Only the process trees of the requested apps are read: the app's main process
/// plus its children (Electron/Chromium helpers such as "Claude Helper (Renderer)"),
/// a few levels deep.
struct CPUSampler {
    private struct Sample { var cpuNanos: UInt64; var at: UInt64 }
    private var previous: [pid_t: Sample] = [:]

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// CPU percent over the last interval, keyed by executable path. Processes seen
    /// for the first time report nothing until the next sample.
    mutating func sample(appPaths: [String]) -> [String: Double] {
        let now = DispatchTime.now().uptimeNanoseconds
        var current: [pid_t: Sample] = [:]
        var usage: [String: Double] = [:]

        for appPath in Set(appPaths) {
            guard let main = AXSearch.runningApp(atPath: appPath)?.processIdentifier else { continue }
            for pid in Self.processTree(root: main) {
                guard let nanos = Self.cpuNanos(pid), let path = Self.executablePath(pid) else { continue }
                current[pid] = Sample(cpuNanos: nanos, at: now)
                if let prev = previous[pid], now > prev.at, nanos >= prev.cpuNanos {
                    usage[path, default: 0] += Double(nanos - prev.cpuNanos) / Double(now - prev.at) * 100
                }
            }
        }
        previous = current
        return usage
    }

    /// The process and its descendants (up to 3 levels).
    private static func processTree(root: pid_t) -> [pid_t] {
        var all: [pid_t] = [root]
        var level: [pid_t] = [root]
        for _ in 0..<3 {
            var next: [pid_t] = []
            for parent in level { next += children(of: parent) }
            if next.isEmpty { break }
            all += next
            level = next
        }
        return all
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &buffer,
                                  Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// Total user + system CPU time used by the process, in nanoseconds.
    private static func cpuNanos(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // These are mach time units (nanoseconds on Intel, ticks on Apple silicon).
        let ticks = info.pti_total_user + info.pti_total_system
        return ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
