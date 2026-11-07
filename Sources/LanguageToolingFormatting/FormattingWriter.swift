/// Shared deterministic whitespace and indentation mechanics. Languages retain
/// complete control over when tokens cause indentation or line breaks.
public struct FormattingWriter: Sendable {
    public let indentationWidth: Int
    public private(set) var indentationLevel = 0
    public private(set) var lines: [String] = []
    public private(set) var currentLine = ""

    public init(indentationWidth: Int = 2) {
        self.indentationWidth = max(1, indentationWidth)
    }

    public var lastCharacter: Character? { currentLine.last }
    public var isCurrentLineEmpty: Bool { currentLine.isEmpty }

    public mutating func indent() { indentationLevel += 1 }
    public mutating func dedent() { indentationLevel = max(0, indentationLevel - 1) }

    public mutating func append(_ text: String) {
        if currentLine.isEmpty {
            currentLine = String(
                repeating: " ",
                count: indentationLevel * indentationWidth)
        }
        currentLine += text
    }

    public mutating func space() {
        guard !currentLine.isEmpty,
              currentLine.last?.isWhitespace == false else { return }
        currentLine.append(" ")
    }

    public mutating func trimTrailingWhitespace() {
        while currentLine.last?.isWhitespace == true { currentLine.removeLast() }
    }

    public mutating func lineBreak() {
        trimTrailingWhitespace()
        guard !currentLine.isEmpty else { return }
        lines.append(currentLine)
        currentLine = ""
    }

    public mutating func finish(terminalNewline: Bool = true) -> String {
        lineBreak()
        while lines.last?.isEmpty == true { lines.removeLast() }
        let result = lines.joined(separator: "\n")
        return terminalNewline && !result.isEmpty ? result + "\n" : result
    }
}
