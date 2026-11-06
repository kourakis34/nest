import Foundation
import SQLite3

/// Tells when an app has posted a new macOS notification (e.g. Claude's
/// "response finished"), by reading Notification Center's local database read-only.
///
/// Used as the "done" signal for apps whose window is on another desktop or full
/// screen: macOS treats those windows as hidden, so their Stop button and CPU use stop
/// telling the truth, but they still post a notification when a reply is finished.
///
/// Needs Full Disk Access (the same permission Instinct uses). If the database can't
/// be read, or its layout is different on this macOS version, `isAvailable` is false
/// and callers fall back to other signals.
final class NotificationWatcher {
    static let shared = NotificationWatcher()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private(set) var lastError: String?

    deinit { if let db { sqlite3_close(db) } }

    /// Candidate locations: macOS 15+ first, then the older per-user location.
    private static var candidatePaths: [String] {
        var paths = [NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 {
            paths.append(String(cString: buffer) + "com.apple.notificationcenter/db2/db")
        }
        return paths
    }

    /// The newest notification record ID for this app (nil if unreadable), and how
    /// many notifications from it are stored. A higher ID than before = a new notification.
    func latest(bundleID: String) -> (newestID: Int64, count: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard open() else { return nil }
        let sql = """
            SELECT IFNULL(MAX(r.rec_id), 0), COUNT(r.rec_id)
            FROM record r JOIN app a ON a.app_id = r.app_id
            WHERE lower(a.identifier) = lower(?1)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            lastError = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            if let db { sqlite3_close(db) }
            db = nil
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, bundleID, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        lastError = nil
        return (sqlite3_column_int64(stmt, 0), Int(sqlite3_column_int64(stmt, 1)))
    }

    private func open() -> Bool {
        if db != nil { return true }
        for path in Self.candidatePaths where FileManager.default.fileExists(atPath: path) {
            var handle: OpaquePointer?
            if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                db = handle
                return true
            }
            if let handle { sqlite3_close(handle) }
        }
        lastError = "notification database not readable (needs Full Disk Access)"
        return false
    }
}
