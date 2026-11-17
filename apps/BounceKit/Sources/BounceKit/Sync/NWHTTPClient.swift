import Foundation
import Network

// MARK: - Types

public struct NWHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
}

enum NWHTTPClientError: LocalizedError {
    case connectionFailed(String)
    case timedOut
    case invalidResponse(String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .timedOut: return "Request timed out"
        case .invalidResponse(let msg): return "Invalid HTTP response: \(msg)"
        case .transferFailed(let msg): return "Transfer failed: \(msg)"
        }
    }
}

struct NWHTTPFileBody: Sendable {
    let prefix: Data
    let fileURL: URL
    let suffix: Data
}

private final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

// MARK: - NWHTTPClient

/// Minimal HTTP/1.1 client over a single short-lived `NWConnection`.
/// Used by the iOS receiver to reach the Mac sync server on the same
/// Network.framework path Bonjour resolved, avoiding URLSession routing issues.
/// `timeout` is an idle timeout: it restarts whenever bytes move.
enum NWHTTPClient {

    // MARK: Public API

    static func request(
        endpoint: NWEndpoint,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> NWHTTPResponse {
        let head = buildRequest(method: method, path: path, headers: headers, body: body)
        return try await exchange(endpoint: endpoint, head: head, fileBody: nil, timeout: timeout, streamToFile: nil)
    }

    static func upload(
        endpoint: NWEndpoint,
        method: String,
        path: String,
        headers: [String: String] = [:],
        fileBody: NWHTTPFileBody,
        timeout: TimeInterval = 60
    ) async throws -> NWHTTPResponse {
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileBody.fileURL.path)[.size] as? NSNumber
        guard let fileSize else {
            throw NWHTTPClientError.transferFailed("cannot read size of \(fileBody.fileURL.lastPathComponent)")
        }
        let contentLength = fileBody.prefix.count + fileSize.intValue + fileBody.suffix.count
        let head = buildRequestHead(method: method, path: path, headers: headers, contentLength: contentLength)
        return try await exchange(endpoint: endpoint, head: head, fileBody: fileBody, timeout: timeout, streamToFile: nil)
    }

    static func download(
        endpoint: NWEndpoint,
        method: String,
        path: String,
        headers: [String: String] = [:],
        timeout: TimeInterval = 300
    ) async throws -> (url: URL, response: NWHTTPResponse) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        let head = buildRequest(method: method, path: path, headers: headers, body: nil)
        do {
            let response = try await exchange(endpoint: endpoint, head: head, fileBody: nil, timeout: timeout, streamToFile: tempURL)
            return (tempURL, response)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: Exchange

    private static func exchange(
        endpoint: NWEndpoint,
        head: Data,
        fileBody: NWHTTPFileBody?,
        timeout: TimeInterval,
        streamToFile: URL?
    ) async throws -> NWHTTPResponse {
        try Task.checkCancellation()
        let connection = NWConnection(to: endpoint, using: connectionParameters())
        defer { connection.cancel() }
        let watchdog = IdleWatchdog(idleTimeout: timeout)
        let watchdogTask = watchdog.start { connection.cancel() }
        defer { watchdogTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await open(connection, timeout: timeout)
                watchdog.touch()
                try await send(data: head, on: connection)
                watchdog.touch()
                if let fileBody {
                    try await sendFileBody(fileBody, on: connection, watchdog: watchdog)
                }
                return try await receiveResponse(on: connection, watchdog: watchdog, streamToFile: streamToFile)
            } onCancel: {
                connection.cancel()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if watchdog.didFire { throw NWHTTPClientError.timedOut }
            throw error
        }
    }

    // MARK: Connection

    private static func connectionParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }

    private static func open(_ connection: NWConnection, timeout: TimeInterval) async throws {
        let gate = OpenGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation) else { return }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resolve(.success(()))
                    case .failed(let error):
                        gate.resolve(.failure(NWHTTPClientError.connectionFailed(error.localizedDescription)))
                    case .cancelled:
                        gate.resolve(.failure(NWHTTPClientError.connectionFailed("cancelled")))
                    default:
                        break
                    }
                }

                let queue = DispatchQueue.global(qos: .userInitiated)
                queue.asyncAfter(deadline: .now() + timeout) {
                    gate.resolve(.failure(NWHTTPClientError.timedOut))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            gate.resolve(.failure(CancellationError()))
        }
    }

    // MARK: Request building

    private static func buildRequest(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) -> Data {
        let contentLength = (body?.isEmpty == false) ? body?.count : nil
        var data = buildRequestHead(method: method, path: path, headers: headers, contentLength: contentLength)
        if let body { data.append(body) }
        return data
    }

    private static func buildRequestHead(
        method: String,
        path: String,
        headers: [String: String],
        contentLength: Int?
    ) -> Data {
        var lines = ["\(method) \(path) HTTP/1.1", "Host: bounce", "Connection: close"]
        if let contentLength {
            lines.append("Content-Length: \(contentLength)")
        }
        for (key, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            lines.append("\(key): \(value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    // MARK: Send / receive

    private static func send(data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: NWHTTPClientError.transferFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func sendFileBody(_ fileBody: NWHTTPFileBody, on connection: NWConnection, watchdog: IdleWatchdog) async throws {
        try await send(data: fileBody.prefix, on: connection)
        watchdog.touch()
        let handle = try FileHandle(forReadingFrom: fileBody.fileURL)
        defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            try await send(data: chunk, on: connection)
            watchdog.touch()
        }
        try await send(data: fileBody.suffix, on: connection)
        watchdog.touch()
    }

    private static func receiveResponse(
        on connection: NWConnection,
        watchdog: IdleWatchdog,
        streamToFile: URL?
    ) async throws -> NWHTTPResponse {
        var buffer = Data()
        var body = Data()

        var fileHandle: FileHandle?
        if let streamToFile {
            guard FileManager.default.createFile(atPath: streamToFile.path, contents: nil) else {
                throw NWHTTPClientError.transferFailed("cannot create \(streamToFile.lastPathComponent)")
            }
            fileHandle = try FileHandle(forWritingTo: streamToFile)
        }
        defer { try? fileHandle?.close() }

        var headerParsed = false
        var statusCode = -1
        var responseHeaders: [String: String] = [:]
        var contentLength: Int? = nil
        var isChunked = false
        var bodyBytesRead = 0
        var isComplete = false

        while !isComplete {
            let (chunk, reachedEOF) = try await receiveChunk(on: connection)
            if !chunk.isEmpty {
                watchdog.touch()
                buffer.append(chunk)
            }

            if !headerParsed {
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                    guard let headerString = String(data: headerData, encoding: .utf8) else {
                        throw NWHTTPClientError.invalidResponse("non-UTF8 headers")
                    }
                    let parsed = parseResponseHeaders(headerString)
                    statusCode = parsed.statusCode
                    responseHeaders = parsed.headers
                    contentLength = parsed.contentLength
                    isChunked = parsed.isChunked
                    buffer = Data(buffer[headerEnd.upperBound...])
                    headerParsed = true
                } else if reachedEOF {
                    throw NWHTTPClientError.invalidResponse("connection closed before headers")
                } else {
                    continue
                }
            }

            if isChunked {
                let (decoded, remaining, done) = decodeChunkedBody(buffer)
                buffer = remaining
                if !decoded.isEmpty {
                    if let fileHandle {
                        try fileHandle.write(contentsOf: decoded)
                    } else {
                        body.append(decoded)
                    }
                    bodyBytesRead += decoded.count
                }
                if done { isComplete = true }
            } else if let contentLength {
                let needed = contentLength - bodyBytesRead
                let take = min(needed, buffer.count)
                if take > 0 {
                    let slice = buffer.prefix(take)
                    if let fileHandle {
                        try fileHandle.write(contentsOf: slice)
                    } else {
                        body.append(slice)
                    }
                    bodyBytesRead += take
                    buffer = Data(buffer.dropFirst(take))
                }
                if bodyBytesRead >= contentLength { isComplete = true }
            } else {
                if let fileHandle {
                    try fileHandle.write(contentsOf: buffer)
                } else {
                    body.append(buffer)
                }
                bodyBytesRead += buffer.count
                buffer = Data()
                if reachedEOF { isComplete = true }
            }

            if reachedEOF, !isComplete {
                let expected = contentLength.map(String.init) ?? "chunked"
                throw NWHTTPClientError.transferFailed("connection closed after \(bodyBytesRead) of \(expected) body bytes")
            }
        }

        if streamToFile != nil {
            body = Data()
        }

        return NWHTTPResponse(statusCode: statusCode, headers: responseHeaders, body: body)
    }

    private static func receiveChunk(on connection: NWConnection) async throws -> (Data, reachedEOF: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: NWHTTPClientError.transferFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: (data ?? Data(), complete))
                }
            }
        }
    }

    // MARK: Parsing helpers

    private static func parseResponseHeaders(_ headerString: String) -> (statusCode: Int, headers: [String: String], contentLength: Int?, isChunked: Bool) {
        let lines = headerString.components(separatedBy: "\r\n")
        var statusCode = -1
        if let statusLine = lines.first {
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init)
        let isChunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        return (statusCode, headers, contentLength, isChunked)
    }

    /// Returns (decoded body so far, remaining buffer, isComplete).
    private static func decodeChunkedBody(_ data: Data) -> (Data, Data, Bool) {
        var decoded = Data()
        var remaining = data
        let crlf = Data("\r\n".utf8)

        while true {
            guard let crlfRange = remaining.range(of: crlf) else {
                return (decoded, remaining, false)
            }
            let sizeLine = remaining[remaining.startIndex..<crlfRange.lowerBound]
            guard let sizeString = String(data: sizeLine, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: ";").first,
                  let chunkSize = Int(sizeString, radix: 16) else {
                return (decoded, remaining, false)
            }

            let chunkStart = crlfRange.upperBound
            let chunkEnd = chunkStart + chunkSize
            guard chunkEnd <= remaining.endIndex else {
                return (decoded, remaining, false)
            }

            if chunkSize == 0 {
                return (decoded, Data(), true)
            }

            decoded.append(remaining[chunkStart..<chunkEnd])
            remaining = Data(remaining[(chunkEnd + crlf.count)...])
        }
    }
}

// MARK: - Path label

enum NWPathLabel {
    static func from(path: NWPath?) -> String? {
        guard let path, path.status == .satisfied else { return nil }
        if path.usesInterfaceType(.wiredEthernet) { return "USB" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.cellular) { return "Hotspot" }
        if path.usesInterfaceType(.other) { return "Other" }
        return nil
    }

    static func interfaceDescription(path: NWPath?) -> String {
        guard let path else { return "no path" }
        var types: [String] = []
        if path.usesInterfaceType(.wifi) { types.append("wifi") }
        if path.usesInterfaceType(.wiredEthernet) { types.append("wired") }
        if path.usesInterfaceType(.cellular) { types.append("cellular") }
        if path.usesInterfaceType(.other) { types.append("other") }
        if types.isEmpty { types.append("unknown") }
        return types.joined(separator: "+")
    }
}
