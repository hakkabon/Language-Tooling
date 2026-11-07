import IncrementalParsing

public struct ToolingSymbolID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public var description: String { rawValue }
}

public struct ToolingScopeID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
}

public struct ToolingSymbolKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }

    public static let constant = Self(rawValue: "constant")
    public static let variable = Self(rawValue: "variable")
    public static let function = Self(rawValue: "function")
    public static let type = Self(rawValue: "type")
    public static let field = Self(rawValue: "field")
    public static let parameter = Self(rawValue: "parameter")
    public static let module = Self(rawValue: "module")
}

public struct ToolingSymbol: Hashable, Codable, Sendable, Identifiable {
    public let id: ToolingSymbolID
    public let name: String
    public let kind: ToolingSymbolKind
    public let declarationRange: SourceRange
    public let scopeID: ToolingScopeID
    public let detail: String?
    public let modifiers: Set<String>

    public init(
        id: ToolingSymbolID,
        name: String,
        kind: ToolingSymbolKind,
        declarationRange: SourceRange,
        scopeID: ToolingScopeID,
        detail: String? = nil,
        modifiers: Set<String> = []
    ) {
        precondition(!name.isEmpty)
        self.id = id
        self.name = name
        self.kind = kind
        self.declarationRange = declarationRange
        self.scopeID = scopeID
        self.detail = detail
        self.modifiers = modifiers
    }
}

public enum ToolingReferenceRole: String, Hashable, Codable, Sendable {
    case read, write, call, type, unknown
}

public struct ToolingReference: Hashable, Codable, Sendable, Identifiable {
    public let symbolID: ToolingSymbolID
    public let range: SourceRange
    public let role: ToolingReferenceRole
    public var id: String {
        "\(range.location):\(range.length):\(symbolID.rawValue):\(role.rawValue)"
    }

    public init(
        symbolID: ToolingSymbolID,
        range: SourceRange,
        role: ToolingReferenceRole = .unknown
    ) {
        self.symbolID = symbolID
        self.range = range
        self.role = role
    }
}

public struct ToolingScope: Hashable, Codable, Sendable, Identifiable {
    public let id: ToolingScopeID
    public let parentID: ToolingScopeID?
    public let range: SourceRange
    public let symbolIDs: [ToolingSymbolID]

    public init(
        id: ToolingScopeID,
        parentID: ToolingScopeID?,
        range: SourceRange,
        symbolIDs: [ToolingSymbolID]
    ) {
        self.id = id
        self.parentID = parentID
        self.range = range
        self.symbolIDs = symbolIDs
    }
}

/// Language-neutral queries over a language-produced semantic graph.
public struct ToolingSemanticIndex: Hashable, Codable, Sendable {
    public let symbols: [ToolingSymbol]
    public let references: [ToolingReference]
    public let scopes: [ToolingScope]
    private let symbolsByID: [ToolingSymbolID: ToolingSymbol]
    private let scopesByID: [ToolingScopeID: ToolingScope]

    public init(
        symbols: [ToolingSymbol],
        references: [ToolingReference],
        scopes: [ToolingScope]
    ) {
        precondition(Set(symbols.map(\.id)).count == symbols.count)
        precondition(Set(scopes.map(\.id)).count == scopes.count)
        self.symbols = symbols
        self.references = references
        self.scopes = scopes
        symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0) })
        scopesByID = Dictionary(uniqueKeysWithValues: scopes.map { ($0.id, $0) })
    }

    private enum CodingKeys: String, CodingKey {
        case symbols, references, scopes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            symbols: try container.decode([ToolingSymbol].self, forKey: .symbols),
            references: try container.decode([ToolingReference].self, forKey: .references),
            scopes: try container.decode([ToolingScope].self, forKey: .scopes))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(symbols, forKey: .symbols)
        try container.encode(references, forKey: .references)
        try container.encode(scopes, forKey: .scopes)
    }

    public func symbol(id: ToolingSymbolID) -> ToolingSymbol? {
        symbolsByID[id]
    }

    public func symbol(at offset: Int) -> ToolingSymbol? {
        if let reference = references.first(where: { $0.range.containsCursor(offset) }) {
            return symbolsByID[reference.symbolID]
        }
        return symbols.first { $0.declarationRange.containsCursor(offset) }
    }

    public func references(
        to symbolID: ToolingSymbolID,
        includeDeclaration: Bool = true
    ) -> [SourceRange] {
        var result = references.filter { $0.symbolID == symbolID }.map(\.range)
        if includeDeclaration, let symbol = symbolsByID[symbolID] {
            result.insert(symbol.declarationRange, at: 0)
        }
        return result
    }

    public func visibleSymbols(at offset: Int) -> [ToolingSymbol] {
        guard var scope = scopes
            .filter({ $0.range.containsCursor(offset) })
            .min(by: { $0.range.length < $1.range.length }) else { return [] }
        var result: [ToolingSymbol] = []
        var names: Set<String> = []
        while true {
            for id in scope.symbolIDs {
                guard let symbol = symbolsByID[id],
                      names.insert(symbol.name.lowercased()).inserted else { continue }
                result.append(symbol)
            }
            guard let parent = scope.parentID,
                  let next = scopesByID[parent] else { break }
            scope = next
        }
        return result
    }

    public func renameEdits(
        symbolID: ToolingSymbolID,
        to newName: String
    ) -> [ToolingTextEdit] {
        guard !newName.isEmpty else { return [] }
        return references(to: symbolID).map {
            .init(range: $0, replacement: newName)
        }
    }
}

private extension SourceRange {
    func containsCursor(_ offset: Int) -> Bool {
        offset >= lowerBound && offset <= upperBound
    }
}
