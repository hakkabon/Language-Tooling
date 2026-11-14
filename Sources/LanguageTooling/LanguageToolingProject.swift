import IncrementalParsing

public struct ToolingDocumentURI: RawRepresentable, Hashable, Codable, Sendable,
    Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) { self.init(rawValue: rawValue) }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ToolingProjectDocument: Sendable {
    public let uri: ToolingDocumentURI
    public let languageID: String
    public let snapshot: SourceSnapshot
    public let analysis: LanguageProviderAnalysis

    public init(
        uri: ToolingDocumentURI,
        languageID: String,
        snapshot: SourceSnapshot,
        analysis: LanguageProviderAnalysis
    ) {
        precondition(!languageID.isEmpty)
        self.uri = uri
        self.languageID = languageID
        self.snapshot = snapshot
        self.analysis = analysis
    }
}

public struct ToolingProjectSnapshot: Sendable {
    public let revision: UInt64
    public let documents: [ToolingProjectDocument]

    public init(revision: UInt64, documents: [ToolingProjectDocument]) {
        self.revision = revision
        self.documents = documents.sorted { $0.uri < $1.uri }
    }
}

public struct ToolingProjectDocumentUpdate: Sendable {
    public let uri: ToolingDocumentURI
    public let languageID: String
    public let snapshot: SourceSnapshot
    public let change: SourceChange?

    public init(
        uri: ToolingDocumentURI,
        languageID: String,
        snapshot: SourceSnapshot,
        change: SourceChange? = nil
    ) {
        precondition(!languageID.isEmpty)
        self.uri = uri
        self.languageID = languageID
        self.snapshot = snapshot
        self.change = change
    }
}

public struct ToolingWorkspaceEdit: Hashable, Codable, Sendable {
    public let changes: [ToolingDocumentURI: [ToolingTextEdit]]

    public init(changes: [ToolingDocumentURI: [ToolingTextEdit]]) {
        self.changes = changes.filter { !$0.value.isEmpty }
    }
}

public struct ToolingProjectUpdateResult: Sendable {
    public let revision: UInt64
    public let rebuiltDocuments: Set<ToolingDocumentURI>
    public let reusedDocuments: Set<ToolingDocumentURI>
    public let removedDocuments: Set<ToolingDocumentURI>
    public let evidence: IncrementalExecutionEvidence
}

public enum LanguageToolingProjectError: Error, Hashable, Sendable {
    case operationInProgress
    case staleRevision(previous: UInt64, proposed: UInt64)
    case duplicateDocument(ToolingDocumentURI)
    case unknownLanguage(String)
    case unknownDocument(ToolingDocumentURI)
    case inconsistentLanguage(
        uri: ToolingDocumentURI, previous: String, proposed: String)
}

/// Language-owned cross-file policy. The workspace owns document lifecycle;
/// resolvers own imports, visibility, overload rules, and project symbol IDs.
public protocol LanguageToolingProjectResolver: Sendable {
    /// Publish resolver state only when this operation succeeds. A thrown
    /// error leaves the previously committed revision available for queries.
    func update(_ snapshot: ToolingProjectSnapshot) async throws
    /// Return nil to delegate completion to the document provider.
    func completions(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> [ToolingCompletionItem]?
    func definition(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> ToolingLocation?
    func references(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> [ToolingLocation]
    func rename(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition,
        to newName: String
    ) async throws -> ToolingWorkspaceEdit
}

public extension LanguageToolingProjectResolver {
    func completions(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> [ToolingCompletionItem]? { nil }

    func definition(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> ToolingLocation? { nil }

    func references(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> [ToolingLocation] { [] }

    func rename(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition,
        to newName: String
    ) async throws -> ToolingWorkspaceEdit {
        throw LanguageToolingError.unsupportedOperation("projectRename")
    }
}

/// Consumer-facing multi-document host shared by editors, REPLs, workbenches,
/// and language-server transports.
public actor LanguageToolingProject {
    private struct Entry {
        let languageID: String
        let document: LanguageToolingDocument
    }

    private let providers: [String: any LanguageToolingProvider]
    private let resolver: (any LanguageToolingProjectResolver)?
    private var entries: [ToolingDocumentURI: Entry] = [:]
    private var currentSnapshot: ToolingProjectSnapshot?
    private var operationInProgress = false

    public init(
        providers: [any LanguageToolingProvider],
        resolver: (any LanguageToolingProjectResolver)? = nil
    ) {
        var table: [String: any LanguageToolingProvider] = [:]
        for provider in providers {
            precondition(table[provider.descriptor.id] == nil)
            table[provider.descriptor.id] = provider
        }
        self.providers = table
        self.resolver = resolver
    }

    public var revision: UInt64? { currentSnapshot?.revision }

    @discardableResult
    public func update(
        revision proposedRevision: UInt64,
        documents proposed: [(uri: ToolingDocumentURI, languageID: String,
                               snapshot: SourceSnapshot)]
    ) async throws -> ToolingProjectUpdateResult {
        try await update(
            revision: proposedRevision,
            documents: proposed.map {
                .init(uri: $0.uri, languageID: $0.languageID,
                      snapshot: $0.snapshot)
            })
    }

    @discardableResult
    public func update(
        revision proposedRevision: UInt64,
        documents proposed: [ToolingProjectDocumentUpdate]
    ) async throws -> ToolingProjectUpdateResult {
        try beginOperation()
        defer { operationInProgress = false }
        let isInitial = currentSnapshot == nil
        if let previous = currentSnapshot?.revision, proposedRevision <= previous {
            throw LanguageToolingProjectError.staleRevision(
                previous: previous, proposed: proposedRevision)
        }
        var inputs: [ToolingDocumentURI: (String, SourceSnapshot, SourceChange?)] = [:]
        for item in proposed {
            guard inputs.updateValue(
                (item.languageID, item.snapshot, item.change),
                forKey: item.uri) == nil else {
                throw LanguageToolingProjectError.duplicateDocument(item.uri)
            }
            guard providers[item.languageID] != nil else {
                throw LanguageToolingProjectError.unknownLanguage(item.languageID)
            }
            if let entry = entries[item.uri], entry.languageID != item.languageID {
                throw LanguageToolingProjectError.inconsistentLanguage(
                    uri: item.uri, previous: entry.languageID,
                    proposed: item.languageID)
            }
        }

        let removed = Set(entries.keys).subtracting(inputs.keys)
        var rebuilt: Set<ToolingDocumentURI> = []
        var reused: Set<ToolingDocumentURI> = []
        var nextEntries: [ToolingDocumentURI: Entry] = [:]
        var output: [ToolingProjectDocument] = []

        let committed = Dictionary(uniqueKeysWithValues:
            (currentSnapshot?.documents ?? []).map { ($0.uri, $0) })
        for uri in inputs.keys.sorted() {
            let (languageID, source, change) = inputs[uri]!
            let entry: Entry
            let analysis: LanguageProviderAnalysis
            let old = committed[uri]
            if let change {
                guard let old, old.snapshot == change.before,
                      change.after == source else {
                    throw LanguageProviderError.inconsistentChange
                }
            }
            if let existing = entries[uri], let old, old.snapshot == source {
                entry = existing
                analysis = old.analysis
                reused.insert(uri)
            } else {
                if let old, source.revision <= old.snapshot.revision {
                    throw SourceEditError.nonIncreasingRevision(
                        base: old.snapshot.revision, proposed: source.revision)
                }
                let provider = providers[languageID]!
                let document = LanguageToolingDocument(
                    provider: provider, documentURI: uri.rawValue)
                entry = Entry(languageID: languageID, document: document)
                // Stage mutable provider state separately. Providers do not
                // currently support forking their committed sessions.
                if let change {
                    try await document.open(change.before)
                    analysis = try await document.apply(change)
                } else {
                    analysis = try await document.open(source)
                }
                rebuilt.insert(uri)
            }
            nextEntries[uri] = entry
            output.append(.init(
                uri: uri, languageID: languageID, snapshot: source,
                analysis: analysis))
        }

        let snapshot = ToolingProjectSnapshot(
            revision: proposedRevision, documents: output)
        try Task.checkCancellation()
        try await resolver?.update(snapshot)
        entries = nextEntries
        currentSnapshot = snapshot
        let evidence = IncrementalExecutionEvidence(
            strategy: isInitial ? .full : .incremental,
            measurements: [.init(
                dimension: .documents,
                reused: reused.count,
                rebuilt: rebuilt.count,
                removed: removed.count,
                strategy: "revisioned-project-documents")])
        return .init(
            revision: proposedRevision, rebuiltDocuments: rebuilt,
            reusedDocuments: reused, removedDocuments: removed,
            evidence: evidence)
    }

    public func diagnostics() throws
        -> [ToolingDocumentURI: [LanguageProviderDiagnostic]] {
        guard let snapshot = currentSnapshot else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        return Dictionary(uniqueKeysWithValues: snapshot.documents.map {
            ($0.uri, $0.analysis.diagnostics)
        })
    }

    public func completions(
        in uri: ToolingDocumentURI, at position: ToolingPosition
    ) async throws -> [ToolingCompletionItem] {
        try beginOperation()
        defer { operationInProgress = false }
        let (snapshot, entry) = try context(uri)
        if let resolver, let items = try await resolver.completions(
            in: snapshot, document: uri, at: position) {
            return items
        }
        return try await entry.document.completions(at: position)
    }

    public func definition(
        in uri: ToolingDocumentURI, at position: ToolingPosition
    ) async throws -> ToolingLocation? {
        try beginOperation()
        defer { operationInProgress = false }
        let (snapshot, entry) = try context(uri)
        if let resolver,
           let result = try await resolver.definition(
            in: snapshot, document: uri, at: position) { return result }
        return try await entry.document.definition(at: position)
    }

    public func references(
        in uri: ToolingDocumentURI, at position: ToolingPosition
    ) async throws -> [ToolingLocation] {
        try beginOperation()
        defer { operationInProgress = false }
        let (snapshot, entry) = try context(uri)
        if let resolver {
            let result = try await resolver.references(
                in: snapshot, document: uri, at: position)
            if !result.isEmpty { return result }
        }
        return try await entry.document.references(at: position)
    }

    public func rename(
        in uri: ToolingDocumentURI,
        at position: ToolingPosition,
        to newName: String
    ) async throws -> ToolingWorkspaceEdit {
        try beginOperation()
        defer { operationInProgress = false }
        let (snapshot, _) = try context(uri)
        guard let resolver else {
            throw LanguageToolingError.unsupportedOperation("projectRename")
        }
        return try await resolver.rename(
            in: snapshot, document: uri, at: position, to: newName)
    }

    private func beginOperation() throws {
        guard !operationInProgress else {
            throw LanguageToolingProjectError.operationInProgress
        }
        operationInProgress = true
    }

    private func context(_ uri: ToolingDocumentURI) throws
        -> (ToolingProjectSnapshot, Entry) {
        guard let snapshot = currentSnapshot else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        guard let entry = entries[uri] else {
            throw LanguageToolingProjectError.unknownDocument(uri)
        }
        return (snapshot, entry)
    }
}
