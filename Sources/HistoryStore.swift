import Foundation
import SQLite3

struct Clip: Equatable {
    let id: Int64
    let text: String
    let copied: Date
}
final class HistoryStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let url: URL
    init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 1500)
        try exec("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-512; CREATE TABLE IF NOT EXISTS clips (id INTEGER PRIMARY KEY, content TEXT NOT NULL UNIQUE, copied REAL NOT NULL); CREATE INDEX IF NOT EXISTS clips_date ON clips(copied DESC,id DESC);")
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "Clipboard database", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func stmt(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s = s else { throw failure() }
        defer { sqlite3_finalize(s) }
        try body(s)
    }
    private func bind(_ text: String, _ s: OpaquePointer, _ index: Int32) {
        _ = text.withCString { sqlite3_bind_text(s, index, $0, Int32(text.utf8.count), transient) }
    }
    private func done(_ s: OpaquePointer) throws {
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    func add(_ text: String, at date: Date = Date()) throws {
        try stmt("INSERT INTO clips(content,copied) VALUES(?,?) ON CONFLICT(content) DO UPDATE SET copied=excluded.copied") { s in
            bind(text,s,1); sqlite3_bind_double(s,2,date.timeIntervalSince1970); try done(s)
        }
    }
    // Preserve original copy timestamp on edits; merge if edited text already exists.
    func replace(_ clip: Clip, with text: String) throws {
        guard text != clip.text else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            try stmt("DELETE FROM clips WHERE id=?") { s in sqlite3_bind_int64(s,1,clip.id); try done(s) }
            try stmt("INSERT INTO clips(content,copied) VALUES(?,?) ON CONFLICT(content) DO UPDATE SET copied=MAX(clips.copied,excluded.copied)") { s in
                bind(text,s,1); sqlite3_bind_double(s,2,clip.copied.timeIntervalSince1970); try done(s)
            }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func count(search: String = "") throws -> Int {
        var result = 0
        try stmt("SELECT count(*) FROM clips WHERE (?='' OR instr(lower(content),lower(?))>0)") { s in
            bind(search,s,1); bind(search,s,2)
            guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }; result = Int(sqlite3_column_int64(s,0))
        }; return result
    }
    func page(search: String = "", limit: Int, offset: Int) throws -> [Clip] {
        var result = [Clip]()
        try stmt("SELECT id,substr(content,1,240),copied FROM clips WHERE (?='' OR instr(lower(content),lower(?))>0) ORDER BY copied DESC,id DESC LIMIT ? OFFSET ?") { s in
            bind(search,s,1); bind(search,s,2); sqlite3_bind_int64(s,3,Int64(limit)); sqlite3_bind_int64(s,4,Int64(offset))
            while true {
                let step = sqlite3_step(s)
                if step == SQLITE_DONE { break }; guard step == SQLITE_ROW else { throw failure() }
                let length = Int(sqlite3_column_bytes(s,1))
                let content = sqlite3_column_text(s,1).map { String(decoding: UnsafeBufferPointer(start:$0,count:length), as: UTF8.self) } ?? ""
                result.append(Clip(id: sqlite3_column_int64(s,0), text:content,copied:Date(timeIntervalSince1970:sqlite3_column_double(s,2))))
            }
        }; return result
    }
    func get(_ id: Int64) throws -> Clip? {
        var result: Clip?
        try stmt("SELECT id,content,copied FROM clips WHERE id=?") { s in
            sqlite3_bind_int64(s,1,id)
            let step = sqlite3_step(s)
            if step == SQLITE_DONE { return }; guard step == SQLITE_ROW else { throw failure() }
            let length = Int(sqlite3_column_bytes(s,1))
            let content = sqlite3_column_text(s,1).map { String(decoding: UnsafeBufferPointer(start:$0,count:length), as: UTF8.self) } ?? ""
            result = Clip(id:sqlite3_column_int64(s,0),text:content,copied:Date(timeIntervalSince1970:sqlite3_column_double(s,2)))
        }; return result
    }
    func remove(_ id: Int64) throws {
        try stmt("DELETE FROM clips WHERE id=?") { s in sqlite3_bind_int64(s,1,id); try done(s) }
    }
    func prune(before date: Date) throws {
        try stmt("DELETE FROM clips WHERE copied < ?") { s in sqlite3_bind_double(s,1,date.timeIntervalSince1970); try done(s) }
        if sqlite3_changes(db) > 0 { try compactIfNeeded() }
    }
    private func compactIfNeeded() throws {
        var free = 0; var total = 0
        try stmt("PRAGMA freelist_count") { s in if sqlite3_step(s) == SQLITE_ROW { free = Int(sqlite3_column_int(s,0)) } }
        try stmt("PRAGMA page_count") { s in if sqlite3_step(s) == SQLITE_ROW { total = Int(sqlite3_column_int(s,0)) } }
        if free > 32 && free * 3 > total { try exec("VACUUM") }
    }
    func clear() throws { try exec("DELETE FROM clips; VACUUM;") }
}
