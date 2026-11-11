import IncrementalParsing

/// Consumer-side document lifecycle shared by editors, REPLs, workbenches,
/// and language-server transports. The language provider continues to own all
/// mutable analysis state; consumers only retain the accepted source snapshot
/// and its portable analysis.
public actor LanguageToolingDocument {
    public nonisolated let descriptor: LanguageProviderDescriptor

    private let session: any LanguageToolingSession
    public private(set) var snapshot: SourceSnapshot?
    public private(set) var analysis: LanguageProviderAnalysis?

    public init(
        provider: any LanguageToolingProvider,
        documentURI: String? = nil
    ) {
        descriptor = provider.descriptor
        session = documentURI.map(provider.makeToolingSession(documentURI:))
            ?? provider.makeToolingSession()
    }

    @discardableResult
    public func open(_ snapshot: SourceSnapshot) async throws
        -> LanguageProviderAnalysis {
        try validateRevision(of: snapshot)
        let result = try await session.analyze(snapshot, change: nil)
        self.snapshot = snapshot
        analysis = result
        return result
    }

    @discardableResult
    public func update(
        _ snapshot: SourceSnapshot,
        change: SourceChange? = nil
    ) async throws -> LanguageProviderAnalysis {
        try validateRevision(of: snapshot)
        if let change {
            guard self.snapshot == change.before, change.after == snapshot else {
                throw LanguageProviderError.inconsistentChange
            }
        }
        let result = try await session.analyze(snapshot, change: change)
        self.snapshot = snapshot
        analysis = result
        return result
    }

    @discardableResult
    public func apply(_ edit: SourceEdit) async throws
        -> LanguageProviderAnalysis {
        guard let snapshot else { throw LanguageToolingError.documentNotAnalyzed }
        return try await apply(edit.applying(to: snapshot))
    }

    @discardableResult
    public func apply(_ batch: SourceEditBatch) async throws
        -> LanguageProviderAnalysis {
        guard let snapshot else { throw LanguageToolingError.documentNotAnalyzed }
        return try await apply(batch.applying(to: snapshot))
    }

    @discardableResult
    public func apply(_ change: SourceChange) async throws
        -> LanguageProviderAnalysis {
        try await update(change.after, change: change)
    }

    public func completions(at position: ToolingPosition) async throws
        -> [ToolingCompletionItem] {
        try requireDocument()
        return try await session.completions(at: position)
    }

    public func definition(at position: ToolingPosition) async throws
        -> ToolingLocation? {
        try requireDocument()
        return try await session.definition(at: position)
    }

    public func hover(at position: ToolingPosition) async throws
        -> ToolingHover? {
        try requireDocument()
        return try await session.hover(at: position)
    }

    public func references(at position: ToolingPosition) async throws
        -> [ToolingLocation] {
        try requireDocument()
        return try await session.references(at: position)
    }

    public func semanticTokens() async throws -> ToolingSemanticTokensResult {
        try requireDocument()
        return try await session.semanticTokens()
    }

    public func format() async throws -> String {
        guard let snapshot else { throw LanguageToolingError.documentNotAnalyzed }
        return try await session.format(snapshot)
    }

    public func previewHTML() async throws -> String? {
        guard let snapshot else { throw LanguageToolingError.documentNotAnalyzed }
        return try await session.previewHTML(snapshot)
    }

    private func requireDocument() throws {
        guard snapshot != nil else { throw LanguageToolingError.documentNotAnalyzed }
    }

    private func validateRevision(of proposed: SourceSnapshot) throws {
        guard let current = snapshot else { return }
        guard proposed.revision > current.revision else {
            throw SourceEditError.nonIncreasingRevision(
                base: current.revision,
                proposed: proposed.revision
            )
        }
    }
}
