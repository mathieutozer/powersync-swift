import Foundation
import PowerSync
import Testing

struct AbsolutePathTests {
    @Test func absolutePathOpensWritesAndDeletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ps-abs-\(UUID().uuidString)")
        let path = root.appendingPathComponent("nested/replica.sqlite").path
        defer { try? FileManager.default.removeItem(at: root) }

        let db = PowerSyncDatabase(
            schema: Schema(tables: [Table(name: "items", columns: [.text("name")])]),
            dbFilename: path,
            logger: DefaultLogger()
        )
        _ = try await db.execute(
            sql: "INSERT INTO items (id, name) VALUES (uuid(), ?)", parameters: ["a"])
        let count = try await db.get("SELECT count(*) FROM items") { try $0.getInt(index: 0) }
        #expect(count == 1)
        #expect(FileManager.default.fileExists(atPath: path))

        try await db.close(deleteDatabase: true)

        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("nested").path)) ?? []
        #expect(left.filter { $0.hasPrefix("replica.sqlite") }.isEmpty)
    }
}
