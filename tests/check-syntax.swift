import Foundation

struct Highlight: Decodable {
    let begin: String
    let regularExpression: Bool
}

struct Outline: Decodable {
    let pattern: String
    let template: String
}

struct SyntaxCase: Decodable {
    let category: String
    let source: String
    let matches: [String]
}

struct InlineComment: Decodable {
    let begin: String
    let leadingOnly: Bool?
}

struct BlockComment: Decodable {
    let begin: String
    let end: String
    let isNestable: Bool?
}

struct Comments: Decodable {
    // CotEditor's synthesized decoder requires both arrays, including empty arrays.
    let inlines: [InlineComment]
    let blocks: [BlockComment]
}

struct PairDelimiter: Decodable {
    let begin: String
    let end: String
    let escapeCharacter: String?
    let isMultiline: Bool?
    let prefixes: [String]?
}

struct Edit: Decodable {
    let comment: Comments?
    let stringDelimiters: [PairDelimiter]?
    let characterDelimiters: [PairDelimiter]?
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let decoder = JSONDecoder()
let package = root.appendingPathComponent("Surge.cotsyntax")
let edit = try decoder.decode(
    Edit.self, from: Data(contentsOf: package.appendingPathComponent("Edit.json")))
precondition(edit.comment?.inlines.isEmpty == false)
let highlights = try decoder.decode(
    [String: [Highlight]].self,
    from: Data(contentsOf: package.appendingPathComponent("Regex/Highlights.json"))
)
let patterns = try highlights.mapValues { rules in
    try rules.map { rule in
        precondition(rule.regularExpression)
        return try NSRegularExpression(pattern: rule.begin, options: .anchorsMatchLines)
    }
}
let cases = try decoder.decode(
    [SyntaxCase].self,
    from: Data(contentsOf: root.appendingPathComponent("tests/syntax-cases.json"))
)

for test in cases {
    let source = test.source as NSString
    let results = patterns[test.category]!.flatMap { pattern in
        pattern.matches(in: test.source, range: NSRange(location: 0, length: source.length))
    }.sorted { $0.range.location < $1.range.location }
    let matches = results.map { source.substring(with: $0.range) }
    precondition(
        matches == test.matches, "\(test.category): expected \(test.matches), received \(matches)")
}

let outlines = try decoder.decode(
    [Outline].self,
    from: Data(contentsOf: package.appendingPathComponent("Regex/Outlines.json"))
)
let source =
    "#!name=Example\n[General]\n[Proxy Group]\n#!include local.dconf\n# [Ignored]\n[Ruleset Local]"
let range = NSRange(source.startIndex..., in: source)
let entries = try outlines.flatMap { outline in
    let pattern = try NSRegularExpression(pattern: outline.pattern, options: .anchorsMatchLines)
    return pattern.matches(in: source, range: range).map { match in
        (
            match.range.location,
            pattern.replacementString(for: match, in: source, offset: 0, template: outline.template)
        )
    }
}.sorted { $0.0 < $1.0 }.map { $0.1 }
precondition(
    entries == ["Example", "General", "Proxy Group", "Include: local.dconf", "Ruleset Local"])
print(
    "Surge syntax: \(cases.count) highlight cases and outline extraction passed with Foundation ICU."
)
