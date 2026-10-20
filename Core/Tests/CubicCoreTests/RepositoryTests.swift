import Foundation
import Testing
import CSQLite3
@testable import CubicCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CubicCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func tamper(_ url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw CoreError.storage("test open failed") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CoreError.storage("test SQL failed") }
}

@Test func repositoryRoundTripExportImportAndVersionBackup() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let repository = try SQLiteWorkspaceRepository(url: url)
    #expect(try repository.load() == .empty)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let original = Workspace.demo(now: now)
    try repository.save(original)
    var changed = original
    try changed.updateRemaining(itemID: "item-a", minutes: 45, now: now)
    try repository.save(changed)
    #expect(try repository.load() == changed)
    let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("workspace.sqlite.backups"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "sqlite" }
    #expect(backups.count == 2)
    // At least one retained version is the original; never read a backup through
    // the repository, since initialization would switch its journal mode to WAL.
    var foundOriginal = false
    for backup in backups {
        var database: OpaquePointer?
        guard sqlite3_open_v2(backup.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { throw CoreError.storage("backup open failed") }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, "SELECT payload FROM workspace", -1, &statement, nil)
        print("QA BACKUP path=\(backup.lastPathComponent) prepare=\(code) error=\(String(cString: sqlite3_errmsg(database)))")
        if code == SQLITE_OK, let statement, sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) {
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            struct Envelope: Decodable { var schemaVersion: Int; var workspace: Workspace }
            let restored = try decoder.decode(Envelope.self, from: data).workspace
            print("QA BACKUP restored_items=\(restored.items.count) remaining=\(String(describing: restored.items.first?.remainingMinutes)) matches=\(restored == original)")
            if restored == original { foundOriginal = true }
        }
        sqlite3_finalize(statement); sqlite3_close(database)
    }
    #expect(foundOriginal)
    let exported = directory.appendingPathComponent("export.json")
    try repository.export(to: exported)
    let other = try SQLiteWorkspaceRepository(url: directory.appendingPathComponent("other.sqlite"))
    #expect(try other.importWorkspace(from: exported) == changed)
    #expect(try other.load() == changed)
    #expect(try SQLiteWorkspaceRepository(url: url).load() == changed)
    let explicitBackup = try repository.backup()
    #expect(FileManager.default.fileExists(atPath: explicitBackup.path))
}

@Test func badImportAndInvalidWorkspaceCannotOverwriteGoodData() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try SQLiteWorkspaceRepository(url: directory.appendingPathComponent("workspace.sqlite"))
    let good = Workspace.demo(now: Date(timeIntervalSince1970: 1_800_000_000))
    try repository.save(good)
    let badFile = directory.appendingPathComponent("bad.json")
    try Data("{broken".utf8).write(to: badFile)
    #expect(throws: CoreError.self) { try repository.importWorkspace(from: badFile) }
    #expect(try repository.load() == good)
    var bad = good; bad.items[0].remainingMinutes = -1
    #expect(throws: CoreError.self) { try repository.save(bad) }
    #expect(try repository.load() == good)
    try Data("{\"schemaVersion\":999,\"workspace\":{}}".utf8).write(to: badFile)
    #expect(throws: CoreError.self) { try repository.importWorkspace(from: badFile) }
    #expect(try repository.load() == good)
    struct Envelope: Encodable { var schemaVersion: Int; var workspace: Workspace }
    var dangling = good; dangling.items[0].projectIDs = ["不存在的项目"]
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
    try encoder.encode(Envelope(schemaVersion: 1, workspace: dangling)).write(to: badFile)
    #expect(throws: CoreError.self) { try repository.importWorkspace(from: badFile) }
    #expect(try repository.load() == good)
    #expect(throws: CoreError.self) { try repository.export(to: repository.url) }
    #expect(throws: CoreError.self) { try repository.export(to: URL(fileURLWithPath: repository.url.path + "-wal")) }
    #expect(try repository.load() == good)
}

@Test func corruptStoredPayloadAndUnknownSchemaAreNeverReplaced() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let repository = try SQLiteWorkspaceRepository(url: url)
    try repository.save(.demo(now: Date(timeIntervalSince1970: 1_800_000_000)))
    try tamper(url, sql: "UPDATE workspace SET payload = X'7B62726F6B656E'")
    #expect(throws: CoreError.self) { try repository.load() }
    #expect(throws: CoreError.self) { try repository.save(.empty) }
    #expect(throws: CoreError.self) { try SQLiteWorkspaceRepository(url: url) }
    try tamper(url, sql: "PRAGMA user_version = 999")
    #expect(throws: CoreError.self) { try repository.save(.empty) }
    #expect(throws: CoreError.self) { try SQLiteWorkspaceRepository(url: url) }
}

@Test func existingGarbageFileRemainsByteForByteUnchanged() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("garbage.sqlite")
    let garbage = Data("This is not SQLite".utf8)
    try garbage.write(to: url)
    #expect(throws: CoreError.self) { try SQLiteWorkspaceRepository(url: url) }
    #expect(try Data(contentsOf: url) == garbage)
}
