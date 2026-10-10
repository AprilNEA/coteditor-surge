import Darwin
import Foundation
import XCTest

@testable import CheckSurge

final class CheckSurgeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("surge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func server(script: String, in directory: URL) throws -> URL {
        let path = directory.appendingPathComponent("server")
        try ("#!/bin/sh\n" + script).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    func testFramesPreserveFragmentedUnicodeAndCoalescedMessages() throws {
        let first = try Frames.encode(["message": "例子🐱"])
        let second = try Frames.encode(["id": 2, "result": NSNull()])
        let stream = first + second
        let split = try XCTUnwrap(stream.range(of: Data("🐱".utf8))).lowerBound + 1
        var frames = Frames(buffer: Data(stream[..<7]))
        XCTAssertNil(try frames.next())
        frames.buffer.append(stream[7..<split])
        XCTAssertNil(try frames.next())
        frames.buffer.append(stream[split...])
        XCTAssertEqual(try frames.next()?["message"] as? String, "例子🐱")
        XCTAssertEqual(try frames.next()?["id"] as? Int, 2)
        XCTAssertNil(try frames.next())

        let separator = try XCTUnwrap(first.range(of: Data("\r\n\r\n".utf8)))
        let header = String(decoding: first[..<separator.lowerBound], as: UTF8.self)
        XCTAssertEqual(header, "Content-Length: \(first[separator.upperBound...].count)")
        XCTAssertGreaterThan(first.count, String(decoding: first, as: UTF8.self).count)
    }

    func testMalformedFramesFailInsteadOfWaiting() {
        for header in ["Content-Length: -1", "Content-Length: invalid", "Other: 2"] {
            var frames = Frames(buffer: Data("\(header)\r\n\r\n{}".utf8))
            XCTAssertThrowsError(try frames.next())
        }
        var frames = Frames(buffer: Data("Content-Length: 2\r\n\r\n[]".utf8))
        XCTAssertThrowsError(try frames.next())
    }

    func testLanguageDetectionAndArgumentParsing() throws {
        let cases: [(String, String?, Language)] = [
            ("", "test.sgmodule", .module),
            ("", "test.LIST", .ruleset),
            ("", "test.sgruleset", .ruleset),
            ("DOMAIN,example.com,DIRECT", "test.dconf", .profile),
            ("# comment\n#!name=Example\n[Rule]\n", nil, .module),
            ("# comment\nDOMAIN,example.com\n", nil, .ruleset),
            ("[Rule]\nFINAL,DIRECT\n", nil, .profile),
            ("", nil, .profile),
        ]
        for (text, path, expected) in cases {
            XCTAssertEqual(Language.detect(text: text, path: path), expected)
        }
        let options = try Options(["--saved", "--language=surge-module", "--", "-config.sgmodule"])
        XCTAssertTrue(options.saved)
        XCTAssertEqual(options.language, .module)
        XCTAssertEqual(options.path, "-config.sgmodule")
        XCTAssertTrue(try Options(["--help"]).help)
        XCTAssertNil(try Options([""]).path)
        XCTAssertThrowsError(try Options(["", "--saved"]))
        XCTAssertThrowsError(try Options(["", "second-path"]))
        for arguments in [
            ["--saved"], ["--language"], ["--language", "invalid"], ["--unknown"], ["a", "b"],
        ] {
            XCTAssertThrowsError(try Options(arguments))
        }
        XCTAssertEqual(try decodeText(Data("\u{FEFF}中文 🐱".utf8)), "中文 🐱")
        XCTAssertThrowsError(try decodeText(Data([0xFF])))
    }

    func testFiltersDiagnosticsRejectsRequestsAndOmitsNullShutdownParameters() throws {
        let directory = try temporaryDirectory()
        let capture = directory.appendingPathComponent("requests")
        let diagnostic: [String: Any] = [
            "range": ["start": ["line": 2, "character": 3], "end": ["line": 2, "character": 5]],
            "message": "current", "severity": 2,
        ]
        func published(uri: String, version: Int, diagnostics: [[String: Any]]) -> [String: Any] {
            [
                "method": "textDocument/publishDiagnostics",
                "params": ["uri": uri, "version": version, "diagnostics": diagnostics],
            ]
        }
        let messages: [[String: Any]] = [
            ["id": 1, "result": [:]],
            ["id": "request", "method": "workspace/configuration", "params": [:]],
            published(uri: "untitled:Other", version: 1, diagnostics: []),
            published(uri: "untitled:Surge", version: 0, diagnostics: []),
            published(uri: "untitled:Surge", version: 1, diagnostics: [diagnostic]),
            ["id": 2, "result": NSNull()],
        ]
        let stream = try messages.reduce(into: Data()) { $0.append(try Frames.encode($1)) }
        let executable = try server(
            script: "printf '%s' \(shellQuote(String(decoding: stream, as: UTF8.self)))\n"
                + "cat > \(shellQuote(capture.path))\n",
            in: directory
        )
        let diagnostics = try checkDocument(text: "[Rule]\nFINAL,DIRECT\n", server: executable)
        XCTAssertEqual(diagnostics.map(\.message), ["current"])
        XCTAssertEqual(report(diagnostics, path: nil), "Untitled:3:4: warning: current")
        var requests = Frames(buffer: try Data(contentsOf: capture))
        var rejectedRequest = false
        var shutdown = false
        while let request = try requests.next() {
            if request["id"] as? String == "request" {
                rejectedRequest = true
                XCTAssertEqual((request["error"] as? [String: Any])?["code"] as? Int, -32601)
            }
            if request["method"] as? String == "shutdown" {
                shutdown = true
                XCTAssertNil(request["params"])
            }
        }
        XCTAssertTrue(rejectedRequest)
        XCTAssertTrue(shutdown)
    }

    func testTimeoutEOFAndBrokenPipeKillAndReapServer() throws {
        for mode in ["timeout", "eof", "blocked-write", "broken-pipe"] {
            let directory = try temporaryDirectory()
            let pidFile = directory.appendingPathComponent("pid")
            var script = "echo $$ > \(shellQuote(pidFile.path))\necho synthetic-stderr >&2\n"
            if mode == "eof" { script += "exec 1>&-\n" }
            if mode == "broken-pipe" { script += "exec 0<&-\n" }
            if mode == "blocked-write" || mode == "broken-pipe" {
                let response = try Frames.encode(["id": 1, "result": [:]])
                script += "printf '%s' \(shellQuote(String(decoding: response, as: UTF8.self)))\n"
            }
            script += "exec /bin/sleep 30\n"
            let executable = try server(script: script, in: directory)
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(
                try checkDocument(
                    text: String(repeating: "x", count: 1_000_000), server: executable, timeout: 1
                ), mode
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("synthetic-stderr"), mode)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3, mode)
            let pid = try XCTUnwrap(
                Int32(
                    String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(
                        in: .whitespacesAndNewlines))
            )
            XCTAssertEqual(kill(pid, 0), -1, mode)
            XCTAssertEqual(errno, ESRCH, mode)
        }
    }

    func testMalformedDiagnosticsFailWithoutAnObjectiveCException() throws {
        let directory = try temporaryDirectory()
        let stream =
            try Frames.encode(["id": 1, "result": [:]])
            + Frames.encode(["method": "textDocument/publishDiagnostics", "params": NSNull()])
        let executable = try server(
            script: "printf '%s' \(shellQuote(String(decoding: stream, as: UTF8.self)))\n"
                + "exec /bin/cat > /dev/null\n",
            in: directory
        )
        XCTAssertThrowsError(try checkDocument(text: "", server: executable)) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid diagnostic parameters"))
        }
    }

    func testAllLanguagesAgainstLiveSurge() throws {
        guard FileManager.default.isExecutableFile(atPath: surgeCLI.path) else {
            throw XCTSkip("Surge CLI is not installed.")
        }
        let cases: [(Language, String, String, Int)] = [
            (.profile, "[Rule]\nFINAL,DIRECT\n", "[Rule]\nFINAL,Missing\n", 1),
            (
                .module, "#!name=Probe\n[General]\nloglevel = notify\n",
                "#!name=Probe\n[Rule]\nBOGUS,example.com\n", 2
            ),
            (.ruleset, "DOMAIN,example.com\n", "# 中文 🐱\nBOGUS,例子🐱.com\n", 1),
        ]
        for (language, valid, invalid, line) in cases {
            XCTAssertTrue(try checkDocument(text: valid, language: language).isEmpty)
            let diagnostics = try checkDocument(text: invalid, language: language)
            let first = try XCTUnwrap(diagnostics.first)
            XCTAssertEqual(first.severity, 1)
            XCTAssertEqual(first.range.start.line, line)
            if language == .ruleset { XCTAssertEqual(first.range.end.character, 14) }
        }
    }

    private func runCLI(arguments: [String], input: Data = Data()) throws -> (Int32, String, String)
    {
        let process = Process()
        process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("check-surge")
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let errors = try stderr.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self)
        )
    }

    func testCLIRejectsInvalidInputAndDisplaysHelp() throws {
        let (helpStatus, help, helpErrors) = try runCLI(arguments: ["--help"])
        XCTAssertEqual(helpStatus, 0)
        XCTAssertTrue(help.contains("Usage: check-surge"))
        XCTAssertTrue(helpErrors.isEmpty)
        let (badStatus, badOutput, badErrors) = try runCLI(arguments: [], input: Data([0xFF]))
        XCTAssertNotEqual(badStatus, 0)
        XCTAssertTrue(badOutput.isEmpty)
        XCTAssertTrue(badErrors.contains("UTF-8"))
        let (missingStatus, _, missingErrors) = try runCLI(arguments: ["--saved"])
        XCTAssertNotEqual(missingStatus, 0)
        XCTAssertTrue(missingErrors.contains("requires a file path"))
    }

    func testCLIUsesUnsavedTextAndPreservesSavedFile() throws {
        guard FileManager.default.isExecutableFile(atPath: surgeCLI.path) else {
            throw XCTSkip("Surge CLI is not installed.")
        }
        let (untitledStatus, _, untitledErrors) = try runCLI(
            arguments: [""], input: Data("[Rule]\nFINAL,DIRECT\n".utf8)
        )
        XCTAssertEqual(untitledStatus, 0)
        XCTAssertEqual(untitledErrors, "Untitled: Surge reported no diagnostics.\n")
        let directory = try temporaryDirectory()
        let path = directory.appendingPathComponent("Surge's example.conf")
        let saved = Data("[Rule]\nFINAL,Missing\n".utf8)
        try saved.write(to: path)
        for useSaved in [false, true] {
            var arguments = [path.path]
            if useSaved { arguments.append("--saved") }
            let (status, output, errors) = try runCLI(
                arguments: arguments, input: Data("\u{FEFF}[Rule]\nFINAL,DIRECT\n".utf8)
            )
            XCTAssertEqual(status, 0)
            XCTAssertTrue(output.isEmpty)
            if useSaved {
                XCTAssertTrue(errors.contains("\(path.path):2:1: error:"))
                XCTAssertTrue(errors.contains("Missing"))
            } else {
                XCTAssertTrue(errors.contains("reported no diagnostics"))
            }
            XCTAssertEqual(try Data(contentsOf: path), saved)
        }
    }
}
