import Darwin
import Foundation

let surgeCLI = URL(fileURLWithPath: "/Applications/Surge.app/Contents/Applications/surge-cli")

struct CheckFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Diagnostic: Decodable {
    struct Position: Decodable {
        let line: Int
        let character: Int
    }
    struct Range: Decodable {
        let start: Position
        let end: Position
    }
    let range: Range
    let severity: Int?
    let message: String
}

struct PublishedDiagnostics: Decodable {
    let uri: String
    let version: Int?
    let diagnostics: [Diagnostic]
}

struct Frames {
    var buffer = Data()

    static func encode(_ message: [String: Any]) throws -> Data {
        var message = message
        message["jsonrpc"] = "2.0"
        let body = try JSONSerialization.data(withJSONObject: message)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    mutating func next() throws -> [String: Any]? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: buffer[..<separator.lowerBound], encoding: .ascii) else {
            throw CheckFailure("Surge returned an invalid frame header.")
        }
        let length = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        guard let length, length >= 0 else {
            throw CheckFailure("Surge returned an invalid Content-Length.")
        }
        guard buffer.distance(from: separator.upperBound, to: buffer.endIndex) >= length else {
            return nil
        }
        let end = buffer.index(separator.upperBound, offsetBy: length)
        let body = buffer[separator.upperBound..<end]
        guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CheckFailure("Surge returned a JSON message that is not an object.")
        }
        buffer.removeSubrange(buffer.startIndex..<end)
        return message
    }
}

final class Connection {
    let input: FileHandle
    let output: FileHandle
    let deadline: TimeInterval
    let timeout: TimeInterval
    private var frames = Frames()

    init(input: FileHandle, output: FileHandle, deadline: TimeInterval, timeout: TimeInterval)
        throws
    {
        self.input = input
        self.output = output
        self.deadline = deadline
        self.timeout = timeout
        for handle in [input, output] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags != -1, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1
            else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func timeoutError() -> CheckFailure {
        CheckFailure("Surge did not complete the check within \(timeout.formatted())s.")
    }

    private func waitFor(_ descriptor: Int32, event: Int16) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw timeoutError() }
            var descriptor = pollfd(fd: descriptor, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if result > 0 { return }
            if result == 0 { throw timeoutError() }
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    func send(_ message: [String: Any]) throws {
        let data = try Frames.encode(message)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try waitFor(input.fileDescriptor, event: Int16(POLLOUT))
                let count = Darwin.write(
                    input.fileDescriptor, bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0 && errno != EINTR && errno != EAGAIN {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
    }

    func receive() throws -> [String: Any] {
        while true {
            if let message = try frames.next() { return message }
            try waitFor(output.fileDescriptor, event: Int16(POLLIN))
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                frames.buffer.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                throw CheckFailure("Surge closed the language server before completion.")
            } else if errno != EINTR && errno != EAGAIN {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    func wait(until predicate: ([String: Any]) throws -> Bool) throws -> [String: Any] {
        while true {
            let message = try receive()
            if let value = message["error"] {
                guard let error = value as? [String: Any], let detail = error["message"] as? String
                else {
                    throw CheckFailure("Surge returned an invalid error response.")
                }
                throw CheckFailure("Surge LSP: \(detail)")
            }
            if message["method"] != nil, let id = message["id"] {
                try send([
                    "id": id,
                    "error": ["code": -32601, "message": "Method not supported"],
                ])
            } else if try predicate(message) {
                return message
            }
        }
    }
}

func checkDocument(
    text: String, path: String? = nil, language: Language? = nil,
    server: URL = surgeCLI, timeout: TimeInterval = 10
) throws -> [Diagnostic] {
    let documentURL = path.map { URL(fileURLWithPath: $0).absoluteURL }
    let uri = documentURL?.absoluteString ?? "untitled:Surge"
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    guard let errorFile = tmpfile() else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { fclose(errorFile) }
    let errors = FileHandle(fileDescriptor: fileno(errorFile), closeOnDealloc: false)
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = server
    process.arguments = ["lsp", "--stdio"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    let terminated = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in terminated.signal() }
    try process.run()

    let result = Result {
        let connection = try Connection(
            input: input.fileHandleForWriting, output: output.fileHandleForReading,
            deadline: deadline, timeout: timeout
        )
        try connection.send([
            "id": 1, "method": "initialize",
            "params": [
                "processId": ProcessInfo.processInfo.processIdentifier,
                "capabilities": [String: Any](),
                "rootUri": documentURL?.deletingLastPathComponent().absoluteString as Any?
                    ?? NSNull(),
            ],
        ])
        _ = try connection.wait { $0["id"] as? Int == 1 }
        try connection.send(["method": "initialized", "params": [String: Any]()])
        // shortcut: One buffer only; add sessions for cross-file editing.
        try connection.send([
            "method": "textDocument/didOpen",
            "params": [
                "textDocument": [
                    "uri": uri,
                    "languageId": (language ?? .detect(text: text, path: path)).rawValue,
                    "version": 1, "text": text,
                ]
            ],
        ])
        var diagnostics: [Diagnostic] = []
        _ = try connection.wait { message in
            guard message["method"] as? String == "textDocument/publishDiagnostics" else {
                return false
            }
            guard let params = message["params"] as? [String: Any] else {
                throw CheckFailure("Surge returned invalid diagnostic parameters.")
            }
            let published = try JSONDecoder().decode(
                PublishedDiagnostics.self, from: JSONSerialization.data(withJSONObject: params)
            )
            guard published.uri == uri, published.version == nil || published.version == 1 else {
                return false
            }
            diagnostics = published.diagnostics
            return true
        }
        try connection.send(["id": 2, "method": "shutdown"])
        _ = try connection.wait { $0["id"] as? Int == 2 }
        try connection.send(["method": "exit"])
        try input.fileHandleForWriting.close()
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        guard terminated.wait(timeout: .now() + remaining) == .success else {
            throw connection.timeoutError()
        }
        guard process.terminationStatus == 0 else {
            throw CheckFailure("Surge exited with status \(process.terminationStatus).")
        }
        return diagnostics
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    switch result {
    case .success(let diagnostics):
        return diagnostics
    case .failure(let error):
        try errors.seek(toOffset: 0)
        let detail = String(decoding: try errors.readToEnd() ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { throw CheckFailure("\(error.localizedDescription)\n\(detail)") }
        throw error
    }
}
