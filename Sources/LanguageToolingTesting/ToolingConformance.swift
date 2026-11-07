import LanguageTooling

public enum ToolingConformanceFailure: Error, Hashable, Sendable {
    case invalidSymbolRange(ToolingSymbolID)
    case danglingReference(ToolingSymbolID)
    case invalidScope(ToolingScopeID)
    case overlappingSemanticTokens
}

public enum ToolingConformance {
    public static func validate(
        index: ToolingSemanticIndex,
        utf16Length: Int
    ) throws {
        let symbolIDs = Set(index.symbols.map(\.id))
        let scopeIDs = Set(index.scopes.map(\.id))
        for symbol in index.symbols {
            guard symbol.declarationRange.upperBound <= utf16Length else {
                throw ToolingConformanceFailure.invalidSymbolRange(symbol.id)
            }
            guard scopeIDs.contains(symbol.scopeID) else {
                throw ToolingConformanceFailure.invalidScope(symbol.scopeID)
            }
        }
        for reference in index.references where !symbolIDs.contains(reference.symbolID) {
            throw ToolingConformanceFailure.danglingReference(reference.symbolID)
        }
        for scope in index.scopes {
            if let parentID = scope.parentID, !scopeIDs.contains(parentID) {
                throw ToolingConformanceFailure.invalidScope(parentID)
            }
            if scope.symbolIDs.contains(where: { !symbolIDs.contains($0) }) {
                throw ToolingConformanceFailure.invalidScope(scope.id)
            }
        }
    }

    public static func validate(tokens: [ToolingSemanticToken]) throws {
        let sorted = tokens.sorted {
            ($0.range.start.line, $0.range.start.character)
                < ($1.range.start.line, $1.range.start.character)
        }
        for pair in zip(sorted, sorted.dropFirst())
            where pair.0.range.end.line == pair.1.range.start.line
                && pair.0.range.end.character > pair.1.range.start.character {
            throw ToolingConformanceFailure.overlappingSemanticTokens
        }
    }
}
