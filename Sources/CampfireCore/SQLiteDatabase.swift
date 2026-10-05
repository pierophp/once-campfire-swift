import CSQLite
import Foundation

/// A cached statement result from a SQLite connection.
public struct SQLiteRow: Sendable {
    private let values: [SQLiteValue]
    init(values: [SQLiteValue]) { self.values = values }

    public func string(_ column: Int) -> String? {
        guard values.indices.contains(column), case .text(let value) = values[column] else { return nil }
        return value
    }

    public func integer(_ column: Int) -> Int64? {
        guard values.indices.contains(column), case .integer(let value) = values[column] else { return nil }
        return value
    }
}

public enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case text(String)
}

private final class SQLiteWorkerState: @unchecked Sendable {
    let condition = NSCondition()
    let capacity: Int
    var jobs: [() -> Void] = []
    var stopping = false

    init(capacity: Int) { self.capacity = max(1, capacity) }

    func enqueue(_ job: @escaping () -> Void) {
        condition.lock()
        while jobs.count >= capacity && !stopping { condition.wait() }
        guard !stopping else { condition.unlock(); return }
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()
    }

    static func run(_ state: SQLiteWorkerState) {
        while true {
            state.condition.lock()
            while state.jobs.isEmpty && !state.stopping { state.condition.wait() }
            guard !state.jobs.isEmpty else { state.condition.unlock(); return }
            let job = state.jobs.removeFirst()
            state.condition.broadcast()
            state.condition.unlock()
            job()
        }
    }
}

private final class SQLiteWorker: @unchecked Sendable {
    private let state: SQLiteWorkerState
    private let thread: Thread

    init(name: String, capacity: Int) {
        let state = SQLiteWorkerState(capacity: capacity)
        self.state = state
        thread = Thread { SQLiteWorkerState.run(state) }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { state.stop() }

    func perform<T>(_ work: @escaping () throws -> T) throws -> T {
        let result = SQLiteWorkerResult<T>()
        state.enqueue { result.complete(Result { try work() }) }
        return try result.wait()
    }
}

private final class SQLiteWorkerResult<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Result<Value, Error>?

    func complete(_ result: Result<Value, Error>) {
        lock.lock(); outcome = result; lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> Value {
        semaphore.wait()
        lock.lock(); defer { lock.unlock() }
        return try outcome!.get()
    }
}

/// One isolated SQLite handle and a bounded per-handle prepared statement cache.
public final class SQLiteConnection: @unchecked Sendable {
    fileprivate let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]
    private var statementOrder: [String] = []
    private let lock = NSRecursiveLock()

    fileprivate init(path: String, queryOnly: Bool) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to allocate SQLite handle"
            if let database { sqlite3_close(database) }
            throw SQLiteError.open(path: path, message: message)
        }
        handle = database
        try configure(queryOnly: queryOnly)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepared(sql, bindings: bindings)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure(result) }
    }

    public func firstRow(_ sql: String, bindings: [SQLiteValue] = []) throws -> SQLiteRow? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepared(sql, bindings: bindings)
        let result = sqlite3_step(statement)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            throw failure(result)
        }
        var values: [SQLiteValue] = []
        values.reserveCapacity(Int(sqlite3_column_count(statement)))
        for index in 0..<sqlite3_column_count(statement) {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: values.append(.integer(sqlite3_column_int64(statement, index)))
            case SQLITE_TEXT:
                values.append(.text(String(cString: sqlite3_column_text(statement, index))))
            default: values.append(.null)
            }
        }
        return SQLiteRow(values: values)
    }

    public func scalarInt(_ sql: String) throws -> Int64? { try firstRow(sql)?.integer(0) }

    fileprivate func configure(queryOnly: Bool) throws {
        try rawExecute("PRAGMA busy_timeout=5000")
        try rawExecute("PRAGMA cache_size=2000")
        try rawExecute("PRAGMA foreign_keys=ON")
        try rawExecute("PRAGMA journal_size_limit=67108864")
        try rawExecute("PRAGMA mmap_size=0")
        if queryOnly {
            try rawExecute("PRAGMA query_only=ON")
        } else {
            let statement = try prepareRaw("PRAGMA journal_mode=WAL")
            _ = sqlite3_step(statement)
            sqlite3_finalize(statement)
            try rawExecute("PRAGMA synchronous=NORMAL")
            try rawExecute("PRAGMA wal_autocheckpoint=0")
        }
    }

    fileprivate func rawExecute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw SQLiteError.query(message)
        }
    }

    private func prepared(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            statement = try prepareRaw(sql)
            if statementOrder.count == 128, let oldest = statementOrder.first, let discarded = statements.removeValue(forKey: oldest) {
                sqlite3_finalize(discarded)
                statementOrder.removeFirst()
            }
            statements[sql] = statement
            statementOrder.append(sql)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let integer): result = sqlite3_bind_int64(statement, index, integer)
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            }
            guard result == SQLITE_OK else { throw failure(result) }
        }
        return statement
    }

    private func prepareRaw(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure(result) }
        return statement
    }

    private func failure(_ code: Int32) -> SQLiteError {
        .query("SQLite error \(code): \(String(cString: sqlite3_errmsg(handle)) )")
    }
}

/// Owns the writer, a fixed set of readers, and a WAL checkpointer for the lifetime of the app.
/// Synchronous work is deliberately submitted away from the HTTP event loops.
public final class SQLiteDatabase: @unchecked Sendable {
    private let writer: SQLiteConnection
    private let writerWorker: SQLiteWorker
    private let readers: [SQLiteConnection]
    private let readerWorkers: [SQLiteWorker]
    private let readerLocks: [NSLock]
    private let nextReader = NSLock()
    private var readerCursor = 0
    private let checkpointer: SQLiteConnection
    private let checkpointerWorker: SQLiteWorker
    private let checkpointTimer: DispatchSourceTimer
    private var lastCheckpointWalBytes = 0
    private let databasePath: String

    public init(path: String, readerCount: Int = Int(ProcessInfo.processInfo.environment["RAILS_MAX_THREADS"] ?? "8") ?? 8, writeQueueCapacity: Int = 256) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw SQLiteError.databaseNotFound(path) }
        let configured = Self.configureSQLite
        guard configured == SQLITE_OK else { throw SQLiteError.configuration(code: configured) }
        databasePath = path
        writer = try SQLiteConnection(path: path, queryOnly: false)
        checkpointer = try SQLiteConnection(path: path, queryOnly: false)
        let count = max(1, readerCount)
        readers = try (0..<count).map { _ in try SQLiteConnection(path: path, queryOnly: true) }
        readerWorkers = (0..<count).map { SQLiteWorker(name: "campfire.database.reader.\($0)", capacity: 256) }
        readerLocks = (0..<count).map { _ in NSLock() }
        writerWorker = SQLiteWorker(name: "campfire.database.writer", capacity: writeQueueCapacity)
        checkpointerWorker = SQLiteWorker(name: "campfire.database.checkpointer", capacity: 1)
        if try writer.firstRow("SELECT 1 FROM sqlite_master WHERE type='table' AND name='messages'") != nil {
            try writer.execute("CREATE INDEX IF NOT EXISTS index_messages_on_room_id_and_created_at ON messages(room_id, created_at)")
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "campfire.database.checkpoint-watch", qos: .utility))
        checkpointTimer = timer
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.checkpointIfNeeded() }
        timer.resume()
    }

    deinit { checkpointTimer.cancel() }

    private static let configureSQLite: Int32 = campfire_sqlite_config_multithread()
    public static var version: String { String(cString: sqlite3_libversion()) }
    public static var hasFTS5: Bool { sqlite3_compileoption_used("ENABLE_FTS5") != 0 }

    /// Runs synchronously on one of the fixed reader connections. Call from a worker, not an event loop.
    public func read<T>(_ body: @escaping (SQLiteConnection) throws -> T) throws -> T {
        for index in readers.indices where readerLocks[index].try() {
            defer { readerLocks[index].unlock() }
            return try body(readers[index])
        }
        nextReader.lock()
        let index = readerCursor
        readerCursor = (readerCursor + 1) % readers.count
        nextReader.unlock()
        return try readerWorkers[index].perform {
            self.readerLocks[index].lock(); defer { self.readerLocks[index].unlock() }
            return try body(self.readers[index])
        }
    }

    /// Runs a serialized immediate transaction. After-commit hooks receive the writer connection
    /// after COMMIT and run in insertion order before the next write is dequeued.
    public func write<T>(_ body: @escaping (SQLiteConnection, inout [(SQLiteConnection) throws -> Void]) throws -> T) throws -> T {
        return try writerWorker.perform {
            try self.writer.execute("BEGIN IMMEDIATE")
            var hooks: [(SQLiteConnection) throws -> Void] = []
            let value: T
            do {
                value = try body(self.writer, &hooks)
                try self.writer.execute("COMMIT")
            } catch {
                try? self.writer.execute("ROLLBACK")
                throw error
            }
            var afterCommitError: Error?
            for hook in hooks {
                do { try hook(self.writer) }
                catch { afterCommitError = afterCommitError ?? error }
            }
            self.restartWALIfNeeded()
            if let afterCommitError { throw afterCommitError }
            return value
        }
    }

    private func checkpointIfNeeded() {
        let walPath = databasePath + "-wal"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: walPath),
              let size = attributes[.size] as? NSNumber else { return }
        let pages = size.intValue / 4096
        guard pages >= 1000, size.intValue - lastCheckpointWalBytes >= 1000 * 4096 else { return }
        _ = try? checkpointerWorker.perform { try self.checkpointer.execute("PRAGMA wal_checkpoint(PASSIVE)") }
        lastCheckpointWalBytes = size.intValue
    }

    private func restartWALIfNeeded() {
        let walPath = databasePath + "-wal"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: walPath),
              let size = attributes[.size] as? NSNumber, size.intValue / 4096 >= 10_000 else { return }
        try? writer.execute("PRAGMA wal_checkpoint(RESTART)")
    }
}

public enum SQLiteError: Error, CustomStringConvertible {
    case databaseNotFound(String)
    case configuration(code: Int32)
    case open(path: String, message: String)
    case query(String)

    public var description: String {
        switch self {
        case .databaseNotFound(let path): "SQLite database not found: \(path)"
        case .configuration(let code): "SQLite multithread configuration failed: \(code)"
        case .open(let path, let message): "Could not open SQLite database at \(path): \(message)"
        case .query(let message): "SQLite query failed: \(message)"
        }
    }
}
