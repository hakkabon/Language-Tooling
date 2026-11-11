import IncrementalParsing

public protocol LanguageToolingProvider: LanguageProvider {
    func makeToolingSession() -> any LanguageToolingSession
    func makeToolingSession(documentURI: String) -> any LanguageToolingSession
}

public extension LanguageToolingProvider {
    func makeSession() -> any LanguageProviderSession { makeToolingSession() }

    /// Document-aware factory used by project hosts. Existing providers remain
    /// source compatible; providers that emit locations should override it.
    func makeToolingSession(documentURI: String) -> any LanguageToolingSession {
        makeToolingSession()
    }
}

public protocol LanguageToolingSession: LanguageProviderSession {
    func completions(at position: ToolingPosition) async throws
        -> [ToolingCompletionItem]
    func definition(at position: ToolingPosition) async throws
        -> ToolingLocation?
    func hover(at position: ToolingPosition) async throws -> ToolingHover?
    func references(at position: ToolingPosition) async throws
        -> [ToolingLocation]
    func semanticTokens() async throws -> ToolingSemanticTokensResult
}

public enum LanguageToolingError: Error, Hashable, Sendable {
    case documentNotAnalyzed
    case invalidPosition(ToolingPosition)
    case unsupportedOperation(String)
}

public extension LanguageToolingSession {
    func completions(at position: ToolingPosition) async throws
        -> [ToolingCompletionItem] {
        throw LanguageToolingError.unsupportedOperation("completion")
    }

    func definition(at position: ToolingPosition) async throws
        -> ToolingLocation? {
        throw LanguageToolingError.unsupportedOperation("definition")
    }

    func hover(at position: ToolingPosition) async throws -> ToolingHover? {
        throw LanguageToolingError.unsupportedOperation("hover")
    }

    func references(at position: ToolingPosition) async throws
        -> [ToolingLocation] {
        throw LanguageToolingError.unsupportedOperation("references")
    }

    func semanticTokens() async throws -> ToolingSemanticTokensResult {
        throw LanguageToolingError.unsupportedOperation("semanticTokens")
    }
}
