import Foundation

enum Language: String, CaseIterable {
    case profile = "surge"
    case module = "surge-module"
    case ruleset = "surge-ruleset"

    static func detect(text: String, path: String?) -> Self {
        switch path.map({ URL(fileURLWithPath: $0).pathExtension.lowercased() }) {
        case "sgmodule": return .module
        case "sgruleset", "list": return .ruleset
        case "dconf": return .profile
        default: break
        }
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#!name=") { return .module }
            if line.hasPrefix("[") { return .profile }
            if line.isEmpty || ["#", ";", "//"].contains(where: line.hasPrefix) { continue }
            if line.range(of: #"^[A-Z][A-Z0-9-]*\s*,"#, options: .regularExpression) != nil {
                return .ruleset
            }
            break
        }
        return .profile
    }
}

struct Options {
    var path: String?
    var saved = false
    var language: Language?
    var help = false

    init(_ arguments: [String]) throws {
        var arguments = arguments.makeIterator()
        var positionalOnly = false
        while let argument = arguments.next() {
            if !positionalOnly && ["--help", "-h"].contains(argument) {
                help = true
                return
            } else if !positionalOnly && argument == "--" {
                positionalOnly = true
            } else if !positionalOnly && argument == "--saved" {
                saved = true
            } else if !positionalOnly
                && (argument == "--language" || argument.hasPrefix("--language="))
            {
                let value =
                    argument == "--language"
                    ? arguments.next() : String(argument.dropFirst("--language=".count))
                guard let value, let language = Language(rawValue: value) else {
                    throw CheckFailure("--language requires surge, surge-module, or surge-ruleset.")
                }
                self.language = language
            } else if !positionalOnly && argument.hasPrefix("-") {
                throw CheckFailure("Unknown option: \(argument)")
            } else if path == nil {
                path = argument
            } else {
                throw CheckFailure("Unexpected argument: \(argument)")
            }
        }
        if path == "" { path = nil }
        if saved && path == nil { throw CheckFailure("--saved requires a file path.") }
    }
}

func decodeText(_ data: Data) throws -> String {
    guard var text = String(data: data, encoding: .utf8) else {
        throw CheckFailure("The document must use UTF-8 encoding.")
    }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    return text
}

func report(_ diagnostics: [Diagnostic], path: String?) -> String {
    let name = path ?? "Untitled"
    if diagnostics.isEmpty { return "\(name): Surge reported no diagnostics." }
    let severities = [1: "error", 2: "warning", 3: "information", 4: "hint"]
    return diagnostics.map { diagnostic in
        let start = diagnostic.range.start
        let severity = diagnostic.severity.flatMap { severities[$0] } ?? "diagnostic"
        return
            "\(name):\(start.line + 1):\(start.character + 1): \(severity): \(diagnostic.message)"
    }.joined(separator: "\n")
}

@main
enum CheckSurgeCLI {
    static func main() throws {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            if options.help {
                print(
                    """
                    Usage: check-surge [--saved] [--language LANGUAGE] [PATH]

                    Check the current document with Surge's offline language server.
                    Read UTF-8 text from stdin unless --saved is supplied.
                    Write diagnostics to stderr. Reported diagnostics exit successfully.

                    --saved              Read PATH instead of stdin.
                    --language LANGUAGE  Use surge, surge-module, or surge-ruleset.
                    --help, -h           Show this help.
                    """
                )
                return
            }
            let data: Data
            if options.saved, let path = options.path {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                data = try FileHandle.standardInput.readToEnd() ?? Data()
            }
            let diagnostics = try checkDocument(
                text: decodeText(data), path: options.path, language: options.language
            )
            try FileHandle.standardError.write(
                contentsOf: Data((report(diagnostics, path: options.path) + "\n").utf8)
            )
        } catch {
            try FileHandle.standardError.write(
                contentsOf: Data("Surge check failed: \(error.localizedDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }
}
