#if os(Linux)
import Foundation
import PowerSync
import Testing

/// On Linux the core extension is a shared library loaded at runtime: point `POWERSYNC_CORE_PATH`
/// at the one `scripts/fetch-linux-core.sh` downloads, or install it in `/usr/local/lib`.
struct LinuxCoreTests {
    @Test func coreLoadsAndReportsVersion() async throws {
        let db = PowerSyncDatabase(
            schema: Schema(tables: [Table(name: "items", columns: [.text("name")])]),
            dbFilename: "linux-core-\(UUID().uuidString).db",
            logger: DefaultLogger()
        )

        let version = try await db.get("SELECT powersync_rs_version()") { try $0.getString(index: 0) }
        try await db.close(deleteDatabase: true)

        #expect(!version.isEmpty)
    }
}
#endif
