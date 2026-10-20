import Foundation
import CSQLite3

private struct WorkspaceEnvelope: Codable {
    var schemaVersion: Int
    var workspace: Workspace
}

/// Synchronous ownership: keep this instance on one background serial queue or actor.
/// Intentionally not Sendable; FULLMUTEX does not make multi-call transactions thread safe.
public final class SQLiteWorkspaceRepository {
    // Additive domain fields intentionally retain the original schema-1 SQLite table and
    // envelope. Reading a legacy payload is read-only: absent baselines/gates stay absent.
    // Current gate eligibility is independent of structural decoding, preserving old facts.
    public let url: URL
    private var database: OpaquePointer?

    public init(url: URL) throws {
        guard url.isFileURL else { throw CoreError.storage("SQLite URL 必须是本地文件") }
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        let existed = FileManager.default.fileExists(atPath: self.url.path)
        if !existed {
            try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (existed ? 0 : SQLITE_OPEN_CREATE)
        let code = sqlite3_open_v2(self.url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开 SQLite"
            if let handle { sqlite3_close(handle) }
            throw CoreError.storage(message)
        }
        self.database = handle
        sqlite3_busy_timeout(handle, 5_000)
        do {
            if !existed {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE workspace (id INTEGER PRIMARY KEY CHECK(id = 1), schema_version INTEGER NOT NULL, payload BLOB NOT NULL, saved_at REAL NOT NULL)")
                    try execute("PRAGMA user_version = 1")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            _ = try load()
            // Only tune a database after proving it is a valid CubicCore store.
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
        } catch {
            sqlite3_close(handle); self.database = nil
            throw error
        }
    }
    deinit { if let database { sqlite3_close(database) } }

    public func load() throws -> Workspace {
        try validateSchema()
        return try readWorkspace()
    }
    public func save(_ workspace: Workspace) throws {
        var workspace = workspace
        // Preserve additive templates when a legacy-shaped caller omits the collection.
        // An explicit soft-delete timestamp is the supported removal operation.
        if workspace.projectTemplates == nil { workspace.projectTemplates = try load().projectTemplates }
        try workspace.validate()
        let payload = try Self.encode(workspace)
        // Check schema before locking, then recheck both schema and payload inside the transaction.
        try validateSchema()
        try execute("BEGIN IMMEDIATE")
        do {
            try validateSchema()
            if try readWorkspace() == workspace { try execute("COMMIT"); return }
            // A second read-only connection snapshots the committed version while the write
            // reservation prevents another writer racing the backup. The writer connection
            // itself cannot be an online-backup source inside its write transaction.
            _ = try makeBackup(automatic: true)
            let statement = try prepare("INSERT INTO workspace(id, schema_version, payload, saved_at) VALUES(1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET schema_version=excluded.schema_version, payload=excluded.payload, saved_at=excluded.saved_at")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_int(statement, 1, Int32(Workspace.schemaVersion)))
            guard payload.count <= Int(Int32.max) else { throw CoreError.storage("Workspace JSON 超过 SQLite blob 长度上限") }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let binding = payload.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), transient)
            }
            try check(binding)
            try check(sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970))
            guard sqlite3_step(statement) == SQLITE_DONE else { throw storageError() }
            try execute("COMMIT")
            try? pruneAutomaticBackups()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    public func export(to destination: URL) throws {
        try requireExternalJSONURL(destination)
        let payload = try Self.encode(load())
        try payload.write(to: destination, options: .atomic)
    }
    public func importWorkspace(from source: URL) throws -> Workspace {
        guard source.isFileURL else { throw CoreError.storage("导入源必须是本地文件") }
        let data = try Data(contentsOf: source)
        let workspace = try Self.decode(data)
        try save(workspace)
        return workspace
    }
    public func backup() throws -> URL {
        try validateSchema()
        try execute("BEGIN IMMEDIATE")
        do {
            _ = try readWorkspace()
            let destination = try makeBackup()
            try execute("COMMIT")
            return destination
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private static func encode(_ workspace: Workspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(WorkspaceEnvelope(schemaVersion: Workspace.schemaVersion, workspace: workspace))
    }
    private static func decode(_ data: Data) throws -> Workspace {
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            struct Header: Decodable { var schemaVersion: Int }
            let header = try decoder.decode(Header.self, from: data)
            guard header.schemaVersion == Workspace.schemaVersion else { throw CoreError.unsupportedSchema(header.schemaVersion) }
            // Both the established envelope and a complete bare Workspace JSON are accepted.
            // Never substitute .empty when decoding or validation fails.
            struct Shape: Decodable { var workspace: Workspace? }
            let shape = try decoder.decode(Shape.self, from: data)
            let workspace = try shape.workspace ?? decoder.decode(Workspace.self, from: data)
            try workspace.validate()
            return workspace
        } catch let error as CoreError { throw error }
        catch { throw CoreError.corruptData("Workspace JSON 无法解码: \(error)") }
    }
    private func requireExternalJSONURL(_ destination: URL) throws {
        guard destination.isFileURL else { throw CoreError.storage("导出目标必须是本地文件") }
        let path = destination.standardizedFileURL.resolvingSymlinksInPath().path
        let protected = [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"]
        guard !protected.contains(path) else { throw CoreError.storage("JSON 导出不可覆盖 SQLite 及其事务文件") }
        // Also protect hard links to the main database.
        if FileManager.default.fileExists(atPath: path) {
            let target = try FileManager.default.attributesOfItem(atPath: path)
            for protectedPath in protected where FileManager.default.fileExists(atPath: protectedPath) {
                let source = try FileManager.default.attributesOfItem(atPath: protectedPath)
                if let targetNumber = target[.systemFileNumber] as? NSNumber,
                   let sourceNumber = source[.systemFileNumber] as? NSNumber,
                   let targetDevice = target[.systemNumber] as? NSNumber,
                   let sourceDevice = source[.systemNumber] as? NSNumber,
                   targetNumber == sourceNumber && targetDevice == sourceDevice {
                    throw CoreError.storage("JSON 导出目标与 SQLite 文件为同一 inode")
                }
            }
        }
    }
    private func validateSchema() throws {
        let integrity = try prepare("PRAGMA quick_check")
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_step(integrity) == SQLITE_ROW, columnText(integrity, 0) == "ok",
              sqlite3_step(integrity) == SQLITE_DONE else { throw CoreError.corruptData("SQLite integrity 检查失败") }
        let version = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(version) }
        guard sqlite3_step(version) == SQLITE_ROW else { throw storageError() }
        let number = Int(sqlite3_column_int64(version, 0))
        guard number == Workspace.schemaVersion else { throw CoreError.unsupportedSchema(number) }
        let columns = try prepare("PRAGMA table_info(workspace)")
        defer { sqlite3_finalize(columns) }
        var actual: [(String, String, Int32, Int32)] = []
        var code = sqlite3_step(columns)
        while code == SQLITE_ROW {
            actual.append((columnText(columns, 1), columnText(columns, 2).uppercased(), sqlite3_column_int(columns, 3), sqlite3_column_int(columns, 5)))
            code = sqlite3_step(columns)
        }
        guard code == SQLITE_DONE else { throw storageError() }
        let expected: [(String, String, Int32, Int32)] = [("id", "INTEGER", 0, 1), ("schema_version", "INTEGER", 1, 0), ("payload", "BLOB", 1, 0), ("saved_at", "REAL", 1, 0)]
        guard actual.count == expected.count, zip(actual, expected).allSatisfy({ pair in
            let (left, right) = pair
            return left.0 == right.0 && left.1 == right.1 && left.2 == right.2 && left.3 == right.3
        }) else { throw CoreError.corruptData("SQLite workspace 表结构不匹配") }
        let objects = try prepare("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        defer { sqlite3_finalize(objects) }
        guard sqlite3_step(objects) == SQLITE_ROW, columnText(objects, 0) == "table", columnText(objects, 1) == "workspace",
              sqlite3_step(objects) == SQLITE_DONE else { throw CoreError.corruptData("SQLite 含未识别表、触发器或索引") }
    }
    private func readWorkspace() throws -> Workspace {
        let statement = try prepare("SELECT id, schema_version, payload, saved_at FROM workspace")
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return .empty }
        guard code == SQLITE_ROW else { throw storageError() }
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, sqlite3_column_int64(statement, 0) == 1,
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER else { throw CoreError.corruptData("SQLite singleton/version 无效") }
        let version = Int(sqlite3_column_int64(statement, 1))
        guard version == Workspace.schemaVersion else { throw CoreError.unsupportedSchema(version) }
        guard sqlite3_column_type(statement, 2) == SQLITE_BLOB,
              sqlite3_column_type(statement, 3) == SQLITE_FLOAT || sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
              sqlite3_column_double(statement, 3).isFinite,
              let bytes = sqlite3_column_blob(statement, 2), sqlite3_column_bytes(statement, 2) > 0 else {
            throw CoreError.corruptData("SQLite payload/saved_at 无效")
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
        let workspace = try Self.decode(data)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CoreError.corruptData("SQLite 含多个 Workspace") }
        return workspace
    }
    private func makeBackup(automatic: Bool = false) throws -> URL {
        let directory = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(automatic ? "auto" : "manual")-schema-\(Workspace.schemaVersion)-\(UUID().uuidString).sqlite")
        var sourceDB: OpaquePointer?, targetDB: OpaquePointer?
        defer {
            if let sourceDB { sqlite3_close(sourceDB) }
            if let targetDB { sqlite3_close(targetDB) }
        }
        guard sqlite3_open_v2(url.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let source = sourceDB else { throw CoreError.storage("无法打开备份源") }
        guard sqlite3_open_v2(destination.path, &targetDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let target = targetDB else { throw CoreError.storage("无法创建版本备份") }
        guard let copy = sqlite3_backup_init(target, "main", source, "main") else {
            throw CoreError.storage("无法初始化 SQLite backup: \(String(cString: sqlite3_errmsg(target)))")
        }
        let step = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            // A failed/incomplete backup is kept as evidence and never used to overwrite the source.
            throw CoreError.storage("SQLite backup 失败: step=\(step), finish=\(finish)")
        }
        // Backup copies the source page header, including WAL mode. Reopen so the
        // destination pager observes that header before converting to a standalone file.
        guard sqlite3_close(target) == SQLITE_OK else { throw CoreError.storage("无法关闭备份目标") }
        targetDB = nil
        guard sqlite3_open_v2(destination.path, &targetDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let sealedTarget = targetDB else { throw CoreError.storage("无法封装备份目标") }
        var modeStatement: OpaquePointer?
        guard sqlite3_prepare_v2(sealedTarget, "PRAGMA journal_mode = DELETE", -1, &modeStatement, nil) == SQLITE_OK,
              let modeStatement else { throw CoreError.storage("无法封装独立 SQLite 备份") }
        let standalone = sqlite3_step(modeStatement) == SQLITE_ROW && columnText(modeStatement, 0).lowercased() == "delete"
        sqlite3_finalize(modeStatement)
        guard standalone else { throw CoreError.storage("备份尚未转换为独立文件") }
        guard sqlite3_close(sealedTarget) == SQLITE_OK else { throw CoreError.storage("无法完成备份封装") }
        targetDB = nil
        // DELETE is confirmed and the only destination handle is closed. SQLite can
        // leave an empty shared-memory companion after online backup; it is no longer used.
        for suffix in ["-wal", "-shm"] {
            let companion = URL(fileURLWithPath: destination.path + suffix)
            if FileManager.default.fileExists(atPath: companion.path) { try FileManager.default.removeItem(at: companion) }
        }
        return destination
    }
    private func pruneAutomaticBackups() throws {
        let directory = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".backups", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("auto-schema-") && $0.pathExtension == "sqlite" }
        var dated: [(URL, Date)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.creationDateKey])
            dated.append((file, values.creationDate ?? Date.distantPast))
        }
        dated.sort { $0.1 > $1.1 }
        for (file, _) in dated.dropFirst(20) {
            try FileManager.default.removeItem(at: file)
            for suffix in ["-wal", "-shm"] {
                let companion = URL(fileURLWithPath: file.path + suffix)
                if FileManager.default.fileExists(atPath: companion.path) { try FileManager.default.removeItem(at: companion) }
            }
        }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw CoreError.storage("数据库已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw storageError() }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard let database else { throw CoreError.storage("数据库已关闭") }
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }
    private func check(_ code: Int32) throws { guard code == SQLITE_OK else { throw storageError() } }
    private func storageError() -> CoreError {
        .storage(database.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库已关闭")
    }
    private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
