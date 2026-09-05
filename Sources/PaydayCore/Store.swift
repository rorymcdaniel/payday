import Foundation
import CSQLite
import Darwin

/// One durable state document, committed transactionally. FULL sync is required
/// before sending each remote write; losing this journal could duplicate money.
public final class Store {
    private var db: OpaquePointer?
    private var lockFD: Int32 = -1
    public private(set) var state: AppState
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        self.state = AppState()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        lockFD = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw AppError("Payday is already open. Use the existing window, then try again.")
        }
        do {
            let path = directory.appendingPathComponent("payday.sqlite").path
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw AppError("Could not open the local history database.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS app_state (id INTEGER PRIMARY KEY CHECK(id=1), document BLOB NOT NULL);")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT document FROM app_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw AppError("Could not read local history.") }
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                let data = Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
                state = try JSONDecoder().decode(AppState.self, from: data)
                guard state.schemaVersion == 1 else { throw AppError("This history was created by a newer version of Payday. Update the app to open it.") }
            } else if result != SQLITE_DONE { throw AppError("Could not read local history.") }
        } catch {
            sqlite3_close(db); db = nil; close(lockFD); lockFD = -1
            throw error
        }
    }

    deinit { sqlite3_close(db); if lockFD >= 0 { close(lockFD) } }

    public func update(_ change: (inout AppState) throws -> Void) throws {
        var next = state
        try change(&next)
        let data = try JSONEncoder().encode(next)
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO app_state(id,document) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document", -1, &statement, nil) == SQLITE_OK else { throw AppError("Could not prepare local history write.") }
            defer { sqlite3_finalize(statement) }
            let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw AppError("Could not save local history. No further YNAB changes will be sent.") }
            try execute("COMMIT")
            state = next
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError("Local database operation failed. No further YNAB changes will be sent.") }
    }
}
