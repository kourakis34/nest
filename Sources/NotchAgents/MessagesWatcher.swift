import Foundation
import SQLite3

/// Watches your one-on-one iMessage chat with an agent (Instinct) and reports
/// "working" (you sent the latest message, no reply yet) and "finished" (a reply arrived).
///
/// 1. Reading the chat
///    Opens ~/Library/Messages/chat.db (where Messages keeps your history) read-only,
///    which needs Full Disk Access. About every 0.7 seconds it fetches the newest
///    message in your one-on-one chat with the agent. The chat is found by the last
///    10 digits of the number, so "+1 (555) 123-4567", "+15551234567" and
///    "5551234567" all match however Messages formatted it. Emails match exactly.
///
/// 2. Deciding the state
///    - Newest message is from you (and under 15 minutes old) → working.
///    - A newer message from the agent appears → finished (green flash), then idle.
///    - Tapbacks/reactions and system items are ignored.
final class MessagesWatcher {
    let name: String
    /// Called on the main thread.
    var onChange: ((_ working: Bool) -> Void)?
    var onFinished: (() -> Void)?

    private(set) var state = "starting"
    private(set) var accessDenied = false

    private let key: String          // last 10 digits, or lowercased email
    private let isEmail: Bool
    private let queue = DispatchQueue(label: "NotchAgents.messages")
    private var timer: DispatchSourceTimer?
    private var db: OpaquePointer?
    private var handleIDs: [Int64] = []
    private var lastHandleRefresh = Date.distantPast
    private var working = false
    private var lastSeenRowID: Int64 = -1
    private let timeout: TimeInterval = 15 * 60

    init(name: String, handle: String) {
        self.name = name
        let raw = handle.trimmingCharacters(in: .whitespaces)
        isEmail = raw.contains("@")
        key = isEmail ? raw.lowercased() : String(raw.filter(\.isNumber).suffix(10))
    }

    deinit {
        timer?.cancel()
        if let db { sqlite3_close(db) }
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(700), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Polling

    private func tick() {
        guard let latest = newestMessage() else {
            update(working: false, finished: false)
            return
        }
        let recent = Date().timeIntervalSince(latest.date) < timeout
        let nowWorking = latest.fromMe && recent
        // A reply = the newest message changed to one from the agent while we were waiting.
        let finished = working && !latest.fromMe && latest.rowID != lastSeenRowID
        lastSeenRowID = latest.rowID
        state = nowWorking ? "waiting for reply" : (latest.fromMe ? "idle (no reply after 15 min)" : "idle")
        update(working: nowWorking, finished: finished)
    }

    private func update(working nowWorking: Bool, finished: Bool) {
        let changed = nowWorking != working
        working = nowWorking
        guard changed || finished else { return }
        DispatchQueue.main.async {
            if changed { self.onChange?(nowWorking) }
            if finished { self.onFinished?() }
        }
    }

    // MARK: - Database

    private func open() -> Bool {
        if db != nil { return true }
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            denied()
            return false
        }
        db = handle
        return true
    }

    private func denied() {
        accessDenied = true
        state = "needs Full Disk Access"
        if let db { sqlite3_close(db) }
        db = nil
        handleIDs = []
    }

    /// All handle rows for this contact (iMessage and SMS each get their own row).
    private func refreshHandles() -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID, id FROM handle", -1, &stmt, nil) == SQLITE_OK else {
            denied(); return false
        }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cstr = sqlite3_column_text(stmt, 1) else { continue }
            let id = String(cString: cstr)
            let match = isEmail ? id.lowercased() == key
                                : String(id.filter(\.isNumber).suffix(10)) == key
            if match { ids.append(sqlite3_column_int64(stmt, 0)) }
        }
        accessDenied = false
        handleIDs = ids
        lastHandleRefresh = Date()
        return true
    }

    private func newestMessage() -> (rowID: Int64, fromMe: Bool, date: Date)? {
        guard key.count >= 7 || isEmail, open() else { return nil }
        // Re-read handles now and then (a first message to a new number creates one).
        if handleIDs.isEmpty || Date().timeIntervalSince(lastHandleRefresh) > 30 {
            guard refreshHandles() else { return nil }
        }
        guard !handleIDs.isEmpty else {
            state = "no chat found for this number yet"
            return nil
        }
        let list = handleIDs.map(String.init).joined(separator: ",")
        // One-on-one chats with this contact (chats where they're the only participant),
        // plus any message tagged directly with their handle.
        let sql = """
            SELECT m.ROWID, m.is_from_me, m.date
            FROM message m
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE (cmj.chat_id IN (
                      SELECT chj.chat_id FROM chat_handle_join chj
                      WHERE chj.handle_id IN (\(list))
                        AND (SELECT COUNT(*) FROM chat_handle_join x WHERE x.chat_id = chj.chat_id) = 1)
                   OR (cmj.chat_id IS NULL AND m.handle_id IN (\(list))))
              AND m.associated_message_type = 0
              AND m.item_type = 0
            ORDER BY m.date DESC
            LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            denied(); return nil
        }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            if rc != SQLITE_DONE { denied() } else { state = "no messages yet" }
            return nil
        }
        accessDenied = false
        let rowID = sqlite3_column_int64(stmt, 0)
        let fromMe = sqlite3_column_int(stmt, 1) == 1
        let raw = Double(sqlite3_column_int64(stmt, 2))
        // Messages stores nanoseconds since 2001-01-01 (seconds on very old macOS).
        let seconds = raw > 1e12 ? raw / 1e9 : raw
        return (rowID, fromMe, Date(timeIntervalSinceReferenceDate: seconds))
    }
}
