import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An internal protocol for HTTP clients.
/// 
/// Outside of tests, this is implemented by ``PlatformHttpClient`` as a thin wrapper around
/// ``URLSession``. In tests, we can use a mock implementation to test the sync client instead.
/// 
/// This is an internal protocol and tailored towards what the sync client actually needs. It is not
/// a general-purpose HTTP client. 
protocol HttpClient: Sendable {
    /// Start streaming a `/sync/stream` response body, emitting individual lines.
    ///
    /// Throws an ``UnexpectedResponseError`` if the response can't be interpreted as sync lines.
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse)

    /// Read a full response body.
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data)
}

struct UnexpectedResponseError: Error, CustomDebugStringConvertible {
    let response: HTTPURLResponse
    let message: String
    
    var debugDescription: String {
        message
    }
}

protocol SyncLineResponse: Sendable, AsyncSequence where AsyncIterator: SyncLineResponseIterator {}

protocol SyncLineResponseIterator: AsyncIteratorProtocol {
    mutating func next() async throws -> SyncLine?
}

enum SyncLine: Sendable {
    case text(contents: String)
    // In the future, we might also want to support splitting BSON objects. Currently, we stream JSON only.
    //case binary(contents: Data)
}

struct PlatformHttpClient: HttpClient {
    let session: URLSession
    
    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse) {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation (Windows, Linux) has no `URLSession.bytes(for:)`, so a session
        // delegate splits the body into lines instead.
        let (response, lines) = try await DelegateSyncLines.start(request: request)
        do {
            try Self.checkSyncLinesMimeType(response)
        } catch {
            lines.cancel()
            throw error
        }
        return (response, lines)
        #else
        let (bytes, originalResponse) = try await session.bytes(for: request)
        let response = originalResponse as! HTTPURLResponse
        try Self.checkSyncLinesMimeType(response)

        struct PlatformSyncLineResponse<Base>: SyncLineResponse where Base : AsyncSequence, Base.Element == UInt8, Base: Sendable {
            let lines: AsyncLineSequence<Base>

            func makeAsyncIterator() -> some SyncLineResponseIterator {
                return PlatformSyncLineResponseIterator<Base>(inner: lines.makeAsyncIterator())
            }
        }

        struct PlatformSyncLineResponseIterator<Base>: SyncLineResponseIterator where Base : AsyncSequence, Base.Element == UInt8, Base: Sendable {
            typealias Element = SyncLine

            var inner: AsyncLineSequence<Base>.AsyncIterator

            mutating func next() async throws -> SyncLine? {
                let line = try await inner.next()
                return line.map { SyncLine.text(contents: $0) }
            }
        }

        return (response, PlatformSyncLineResponse(lines: bytes.lines))
        #endif
    }

    private static func checkSyncLinesMimeType(_ response: HTTPURLResponse) throws {
        let jsonStreamMimeType = "application/x-ndjson"
        if response.mimeType != jsonStreamMimeType {
            throw UnexpectedResponseError(
                response: response,
                message: "Invalid sync lines response, (expected \(jsonStreamMimeType), got \(response.mimeType, default: "")"
            )
        }
    }
    
    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        return (response as! HTTPURLResponse, data)
    }
    
    static let shared = PlatformHttpClient(session: .shared)
}

#if canImport(FoundationNetworking)
/// Sync lines from a response body streamed by ``DelegateSyncLines``.
private struct DelegateSyncLineResponse: SyncLineResponse {
    let stream: AsyncThrowingStream<SyncLine, any Error>
    let continuation: AsyncThrowingStream<SyncLine, any Error>.Continuation

    func makeAsyncIterator() -> DelegateSyncLineResponseIterator {
        DelegateSyncLineResponseIterator(inner: stream.makeAsyncIterator())
    }

    /// Stops the request.
    func cancel() {
        continuation.finish()
    }
}

private struct DelegateSyncLineResponseIterator: SyncLineResponseIterator {
    typealias Element = SyncLine

    var inner: AsyncThrowingStream<SyncLine, any Error>.AsyncIterator

    mutating func next() async throws -> SyncLine? {
        try await inner.next()
    }
}

/// Streams a response body as newline-separated sync lines from `URLSessionDataDelegate` callbacks.
private final class DelegateSyncLines: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Only touched from the session's serial delegate queue.
    private var response: CheckedContinuation<HTTPURLResponse, any Error>?
    private let lines: AsyncThrowingStream<SyncLine, any Error>.Continuation
    private var buffer = Data()

    private init(
        response: CheckedContinuation<HTTPURLResponse, any Error>,
        lines: AsyncThrowingStream<SyncLine, any Error>.Continuation
    ) {
        self.response = response
        self.lines = lines
    }

    /// Starts `request` and returns its response once the headers arrive. Finishing or dropping the
    /// returned lines cancels the request.
    static func start(request: URLRequest) async throws -> (HTTPURLResponse, DelegateSyncLineResponse) {
        let (stream, lines) = AsyncThrowingStream<SyncLine, any Error>.makeStream()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = DelegateSyncLines(response: continuation, lines: lines)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                lines.onTermination = { _ in
                    task.cancel()
                    session.invalidateAndCancel()
                }
                task.resume()
            }
        } onCancel: {
            lines.finish()
        }
        return (response, DelegateSyncLineResponse(stream: stream, continuation: lines))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            self.response?.resume(throwing: URLError(.badServerResponse))
            self.response = nil
            completionHandler(.cancel)
            return
        }
        self.response?.resume(returning: http)
        self.response = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            yieldLine(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let response {
            self.response = nil
            response.resume(throwing: error ?? URLError(.badServerResponse))
        }
        yieldLine(buffer)
        buffer.removeAll()
        lines.finish(throwing: error)
        session.finishTasksAndInvalidate()
    }

    /// Emits one line of the body, without its `\r\n` ending. Blank lines are skipped.
    private func yieldLine(_ bytes: Data) {
        guard var line = String(data: bytes, encoding: .utf8) else { return }
        if line.hasSuffix("\r") { line.removeLast() }
        if !line.isEmpty { lines.yield(.text(contents: line)) }
    }
}
#endif

/// A wrapper around a ``HttpClient`` emitting log events for responses and sync lines.
struct LoggingClient: HttpClient {
    let inner: HttpClient
    let logger: SyncRequestLoggerConfiguration

    fileprivate var shouldLogInfo: Bool {
        logger.requestLevel != .none
    }
    
    fileprivate var shouldLogHeaders: Bool {
        logger.requestLevel == .all || logger.requestLevel == .headers
    }
    
    fileprivate var shouldLogBody: Bool {
        logger.requestLevel == .all || logger.requestLevel == .body
    }

    func receiveSyncLines(request: URLRequest) async throws -> (HTTPURLResponse, any SyncLineResponse) {
        logRequest(request: request)
        do {
            let (response, lines) = try await inner.receiveSyncLines(request: request)
            logResponse(response: response)
            
            return (response, LogSyncLines(logger: self, inner: lines))
        } catch {
            logError(error: error)
            throw error
        }
    }

    func readFully(request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        logRequest(request: request)
        do {
            let (response, data) = try await inner.readFully(request: request)
            logResponse(response: response)
            if shouldLogBody, let content = String(data: data, encoding: .utf8) {
                logger.log("  Response: \(content)")
            }
            return (response, data)
        } catch {
            logError(error: error)
            throw error
        }
    }
    
    private func logRequest(request: URLRequest) {
        if shouldLogInfo, let method = request.httpMethod, let url = request.url {
            logger.log("Starting request to \(method) \(url)")
        }

        if shouldLogHeaders, let headers = request.allHTTPHeaderFields {
            for (key, value) in headers {
                logger.log("with header \(key): \(value)")
            }
        }
        
        if shouldLogBody, let rawBody = request.httpBody, let body = String(data: rawBody, encoding: .utf8) {
            logger.log("with body: \(body)")
        }
        
        if shouldLogInfo {
            logger.log("sending request")
        }
    }
    
    private func logResponse(response: HTTPURLResponse) {
        if shouldLogInfo, let url = response.url {
            logger.log("Got response code \(response.statusCode) on \(url)")
        }
        
        if shouldLogHeaders {
            for (key, value) in response.allHeaderFields {
                logger.log("with header \(key): \(value)")
            }
        }
    }
    
    private func logError(error: any Error) {
        if shouldLogInfo {
            logger.log("Error: \(error)")
        }
    }
}

private struct LogSyncLines: SyncLineResponse, Sendable {
    typealias AsyncIterator = LogSyncLinesIterator
    
    let logger: LoggingClient
    let inner: any SyncLineResponse

    func makeAsyncIterator() -> LogSyncLinesIterator {
        LogSyncLinesIterator(logger: logger, inner: inner.makeAsyncIterator())
    }
}

private struct LogSyncLinesIterator: SyncLineResponseIterator {
    let logger: LoggingClient
    var inner: any SyncLineResponseIterator
    
    mutating func next() async throws -> SyncLine? {
        let line = try await self.inner.next()
        if logger.shouldLogBody {
            switch line {
            case .none:
                logger.logger.log("End of response")
            case .some(.text(contents: let contents)):
                logger.logger.log("Response line: \(contents)")
            }
        }
        
        return line
    }
}
