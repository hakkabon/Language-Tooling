import IncrementalParsing

public struct ToolingPosition: Hashable, Codable, Sendable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        precondition(line >= 0 && character >= 0)
        self.line = line
        self.character = character
    }
}

public struct ToolingRange: Hashable, Codable, Sendable {
    public let start: ToolingPosition
    public let end: ToolingPosition

    public init(start: ToolingPosition, end: ToolingPosition) {
        self.start = start
        self.end = end
    }
}

public struct ToolingLocation: Hashable, Codable, Sendable {
    public let uri: String
    public let range: ToolingRange

    public init(uri: String, range: ToolingRange) {
        precondition(!uri.isEmpty)
        self.uri = uri
        self.range = range
    }
}

public struct ToolingDiagnostic: Hashable, Codable, Sendable, Identifiable {
    public let range: ToolingRange
    public let severity: DiagnosticSeverity
    public let message: String
    public let source: String
    public var id: String { "\(range):\(source):\(message)" }

    public init(
        range: ToolingRange,
        severity: DiagnosticSeverity,
        message: String,
        source: String
    ) {
        precondition(!message.isEmpty && !source.isEmpty)
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }
}

public enum ToolingCompletionKind: String, Hashable, Codable, Sendable {
    case keyword, constant, variable, function, type, field, module
}

public struct ToolingCompletionItem: Hashable, Codable, Sendable, Identifiable {
    public let label: String
    public let kind: ToolingCompletionKind
    public let detail: String
    public let insertText: String
    public var id: String { "\(kind.rawValue):\(label.lowercased())" }

    public init(
        label: String,
        kind: ToolingCompletionKind,
        detail: String,
        insertText: String
    ) {
        precondition(!label.isEmpty)
        self.label = label
        self.kind = kind
        self.detail = detail
        self.insertText = insertText
    }
}

public struct ToolingHover: Hashable, Codable, Sendable {
    public let contents: String
    public let range: ToolingRange

    public init(contents: String, range: ToolingRange) {
        precondition(!contents.isEmpty)
        self.contents = contents
        self.range = range
    }
}

public enum ToolingSemanticTokenType: String, CaseIterable, Hashable, Codable,
    Sendable {
    case keyword, number, string, comment
    case operatorToken = "operator"
    case variable, constant, function, type, field, parameter, module
}

public struct ToolingSemanticToken: Hashable, Codable, Sendable, Identifiable {
    public let range: ToolingRange
    public let type: ToolingSemanticTokenType
    public let isDeclaration: Bool
    public var id: String { "\(range):\(type.rawValue):\(isDeclaration)" }

    public init(
        range: ToolingRange,
        type: ToolingSemanticTokenType,
        isDeclaration: Bool = false
    ) {
        self.range = range
        self.type = type
        self.isDeclaration = isDeclaration
    }
}

public struct ToolingSemanticTokensResult: Hashable, Codable, Sendable {
    public let resultID: String
    public let data: [Int]

    public init(resultID: String, data: [Int]) {
        precondition(!resultID.isEmpty)
        self.resultID = resultID
        self.data = data
    }
}

public struct ToolingTextChange: Hashable, Codable, Sendable {
    /// `nil` represents a full-document replacement.
    public let range: ToolingRange?
    public let text: String

    public init(range: ToolingRange? = nil, text: String) {
        self.range = range
        self.text = text
    }
}

public struct ToolingTextEdit: Hashable, Codable, Sendable {
    public let range: SourceRange
    public let replacement: String

    public init(range: SourceRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public enum ToolingCodeActionKind: String, Hashable, Codable, Sendable {
    case quickFix, refactor, source
}

public struct ToolingCodeAction: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ToolingCodeActionKind
    public let edits: [ToolingTextEdit]

    public init(
        id: String,
        title: String,
        kind: ToolingCodeActionKind,
        edits: [ToolingTextEdit]
    ) {
        precondition(!id.isEmpty && !title.isEmpty && !edits.isEmpty)
        self.id = id
        self.title = title
        self.kind = kind
        self.edits = edits
    }
}

public extension Sequence where Element: Identifiable, Element.ID: Hashable {
    func toolingUniquedByID() -> [Element] {
        var identities: Set<Element.ID> = []
        return filter { identities.insert($0.id).inserted }
    }
}
