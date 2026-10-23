import CSQLite
import PowerSyncCoreShim
#if os(Windows)
import WinSDK
#endif

func registerPowerSyncCoreExtension() throws(PowerSyncError) {
    #if os(Windows)
    let rc = sqlite3_auto_extension(try windowsCoreExtensionEntryPoint())
    #else
    let rc = sqlite3_auto_extension(sqlite3_powersync_init)
    #endif
    if rc != 0 {
        let errStr = String(cString: sqlite3_errstr(rc))

        throw .sqliteError(
            extendedResultCode: rc,
            offset: nil,
            message: "Could not load PowerSync SQLite core extension",
            errorString: errStr,
            sql: nil
        )
    }
}

#if os(Windows)
/// The core extension's DLL from the powersync-sqlite-core release this package pins. There's no
/// Windows build of the xcframework, so apps ship the DLL next to their executable.
#if arch(arm64)
private let windowsCoreExtensionLibrary = "powersync_aarch64.dll"
#else
private let windowsCoreExtensionLibrary = "powersync_x64.dll"
#endif

/// Loads the core extension's DLL and returns its `sqlite3_powersync_init`.
private func windowsCoreExtensionEntryPoint() throws(PowerSyncError) -> @convention(c) () -> Void {
    guard
        let module = windowsCoreExtensionLibrary.withCString(encodedAs: UTF16.self, LoadLibraryW)
    else {
        throw .operationFailed(
            message: "Could not load \(windowsCoreExtensionLibrary) (error \(GetLastError()))")
    }
    guard let entryPoint = GetProcAddress(module, "sqlite3_powersync_init") else {
        throw .operationFailed(
            message: "\(windowsCoreExtensionLibrary) has no sqlite3_powersync_init")
    }
    return unsafeBitCast(entryPoint, to: (@convention(c) () -> Void).self)
}
#endif
