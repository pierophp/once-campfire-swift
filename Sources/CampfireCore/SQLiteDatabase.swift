import CSQLite
import Foundation

public final class SQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw SQLiteError.databaseNotFound(path)
        }
        let configured = SQLiteDatabase.configureSQLite
        guard configured == SQLITE_OK else {
            throw SQLiteError.configuration(code: configured)
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate SQLite handle"
            if let database { sqlite3_close(database) }
            throw SQLiteError.open(path: path, message: message)
        }
        self.handle = database
    }

    deinit {
        sqlite3_close(handle)
    }

    private static let configureSQLite: Int32 = campfire_sqlite_config_multithread()

    public static var version: String { String(cString: sqlite3_libversion()) }

    public static var hasFTS5: Bool {
        sqlite3_compileoption_used("ENABLE_FTS5") != 0
    }
}

public enum SQLiteError: Error, CustomStringConvertible {
    case databaseNotFound(String)
    case configuration(code: Int32)
    case open(path: String, message: String)

    public var description: String {
        switch self {
        case .databaseNotFound(let path): "SQLite database not found: \(path)"
        case .configuration(let code): "SQLite multithread configuration failed: \(code)"
        case .open(let path, let message): "Could not open SQLite database at \(path): \(message)"
        }
    }
}
