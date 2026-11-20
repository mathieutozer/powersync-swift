#if os(Linux)
import Foundation
import FoundationNetworking
import Glibc
import Testing
@testable import PowerSync

/// On Linux, sync lines stream through one long-lived session (`SyncLinesRouter`), routed to each
/// stream by task, instead of a session per stream that was freed when the stream ended: freeing
/// a session whose curl multi handle still watches a socket aborts the process ("Object … of
/// class _MultiHandle deallocated with non-zero retain count"). These run many streams through
/// it, ended by the server or cancelled mid-body (a disconnect, a database closing). Neither
/// reproduces that abort on plain HTTP/1.1 (which the old per-stream sessions passed too); they
/// check that the shared session keeps streaming each request's own lines and keeps working
/// after cancels.
@Suite(.serialized)
struct LinuxSyncStreamTests {
    @Test func cancellingStreamsMidBodyKeepsTheProcessUp() async throws {
        let server = try EndlessLinesServer()
        defer { server.stop() }
        let client = PlatformHttpClient.shared
        for round in 0..<40 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/sync/stream")!)
            request.httpMethod = "POST"
            let (response, lines) = try await client.receiveSyncLines(request: request)
            #expect(response.statusCode == 200)
            let reader = Task {
                var iterator = lines.makeAsyncIterator()
                return try await iterator.next()
            }
            guard case .text(let first)? = try await reader.value else {
                Issue.record("no line in round \(round)")
                return
            }
            #expect(first == "{\"line\":1}")
            // Drop the rest mid-body.
            let drain = Task { for try await _ in lines {} }
            drain.cancel()
            _ = await drain.result
            try await Task.sleep(for: .milliseconds(20))
        }
        // Give any freed session's teardown time to run (and abort) before the test ends.
        try await Task.sleep(for: .milliseconds(500))
    }

    /// A stream the server ends leaves its connection open (keep-alive) in curl's cache.
    @Test func streamsThatEndKeepTheProcessUp() async throws {
        let server = try EndlessLinesServer()
        defer { server.stop() }
        let client = PlatformHttpClient.shared
        for _ in 0..<40 {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/finite")!)
            request.httpMethod = "POST"
            let (_, lines) = try await client.receiveSyncLines(request: request)
            var count = 0
            for try await _ in lines { count += 1 }
            #expect(count == 2)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(500))
    }

    @Test func aCallerAlreadyCancelledStartsNoRequest() async throws {
        let server = try EndlessLinesServer()
        defer { server.stop() }
        let client = PlatformHttpClient.shared
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/sync/stream")!)
        request.httpMethod = "POST"
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.receiveSyncLines(request: request)
        }
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        #expect(server.acceptedCount == 0)
    }
}

/// A plain HTTP/1.1 server on 127.0.0.1 that answers every request with an ndjson body sent in
/// chunks: one line at once, then one every 100 ms, forever.
private final class EndlessLinesServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var accepted = 0

    init() throws {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    var acceptedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    private func acceptLoop() {
        while !isStopped {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            lock.lock()
            accepted += 1
            lock.unlock()
            let thread = Thread { [self] in serve(connection) }
            thread.start()
        }
    }

    private func send(_ connection: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { Glibc.send(connection, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) } == bytes.count
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Each request on the connection (keep-alive): read its head, then answer.
        while !isStopped {
            let read = recv(connection, &buffer, buffer.count, 0)
            guard read > 0 else { return }
            let finite = String(decoding: buffer[0..<read], as: UTF8.self).hasPrefix("POST /finite")
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n"
            guard send(connection, head) else { return }
            var line = 1
            while !isStopped {
                let body = "{\"line\":\(line)}\n"
                let chunk = String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n"
                guard send(connection, chunk) else { return }
                line += 1
                if finite && line > 2 {
                    guard send(connection, "0\r\n\r\n") else { return }
                    break
                }
                usleep(100_000)
            }
        }
    }
}
#endif
