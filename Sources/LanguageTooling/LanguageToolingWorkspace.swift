import IncrementalParsing

public enum WorkspacePriority: Int, Sendable {
    case background, interactive
}

public enum WorkspaceSchedulingError: Error, Equatable, Sendable {
    case noRevision
    case superseded(requested: UInt64, current: UInt64)
    case queueFull
    case documentLimitExceeded
    case sourceBudgetExceeded
}

public struct WorkspaceDemandResult<Value: Sendable>: Sendable {
    public let revision: UInt64
    public let value: Value
    /// Nil when this request used the already materialized generation.
    public let analysis: ToolingProjectUpdateResult?
}

/// One scheduler per workspace. Submitting sources does not run a provider.
/// The first query materializes the project because resolvers see all files.
public actor LanguageToolingWorkspace {
    private struct Waiter {
        let id: UInt64
        let revision: UInt64
        let priority: WorkspacePriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let project: LanguageToolingProject
    private let maximumPendingRequests: Int
    private let maximumDocuments: Int
    private let maximumSourceBytes: Int
    private let maximumEditOperations: Int
    private var pending: [Waiter] = []
    private var sequence: UInt64 = 0
    private var running = false
    private var cancelRunning: (@Sendable () -> Void)?
    private var submitted: (revision: UInt64, documents: [ToolingProjectDocumentUpdate])?

    public init(
        providers: [any LanguageToolingProvider],
        resolver: (any LanguageToolingProjectResolver)? = nil,
        maximumPendingRequests: Int = 64,
        maximumDocuments: Int = 1_000,
        maximumSourceBytes: Int = 64 * 1024 * 1024,
        maximumEditOperations: Int = 100_000
    ) {
        precondition(maximumPendingRequests >= 0 && maximumDocuments >= 0)
        precondition(maximumSourceBytes >= 0 && maximumEditOperations >= 0)
        project = LanguageToolingProject(providers: providers, resolver: resolver)
        self.maximumPendingRequests = maximumPendingRequests
        self.maximumDocuments = maximumDocuments
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumEditOperations = maximumEditOperations
    }

    public func submit(revision: UInt64, documents: [ToolingProjectDocumentUpdate]) throws {
        if let previous = submitted?.revision, revision <= previous {
            throw LanguageToolingProjectError.staleRevision(previous: previous, proposed: revision)
        }
        guard documents.count <= maximumDocuments else {
            throw WorkspaceSchedulingError.documentLimitExceeded
        }
        var uris: Set<ToolingDocumentURI> = []
        for document in documents where !uris.insert(document.uri).inserted {
            throw LanguageToolingProjectError.duplicateDocument(document.uri)
        }
        var remainingBytes = maximumSourceBytes
        var remainingEdits = maximumEditOperations
        func charge(_ text: String) throws {
            let bytes = text.utf8.count
            guard bytes <= remainingBytes else {
                throw WorkspaceSchedulingError.sourceBudgetExceeded
            }
            remainingBytes -= bytes
        }
        for document in documents {
            try charge(document.snapshot.text)
            if let change = document.change, change.after != document.snapshot {
                throw LanguageProviderError.inconsistentChange
            }
            if let change = document.change {
                guard change.replacements.count <= remainingEdits else {
                    throw WorkspaceSchedulingError.sourceBudgetExceeded
                }
                remainingEdits -= change.replacements.count
                try charge(change.before.text)
                for replacement in change.replacements {
                    try charge(replacement.replacement)
                }
            }
        }
        submitted = (revision, documents)
        cancelRunning?()
        for waiter in pending {
            waiter.continuation.resume(throwing: WorkspaceSchedulingError.superseded(
                requested: waiter.revision, current: revision))
        }
        pending.removeAll()
    }

    public func diagnostics(priority: WorkspacePriority = .background) async throws
        -> WorkspaceDemandResult<[ToolingDocumentURI: [LanguageProviderDiagnostic]]> {
        try await demand(priority: priority) { try await $0.diagnostics() }
    }

    public func definition(in uri: ToolingDocumentURI, at position: ToolingPosition)
        async throws -> WorkspaceDemandResult<ToolingLocation?> {
        try await demand { try await $0.definition(in: uri, at: position) }
    }

    public func completions(in uri: ToolingDocumentURI, at position: ToolingPosition)
        async throws -> WorkspaceDemandResult<[ToolingCompletionItem]> {
        try await demand { try await $0.completions(in: uri, at: position) }
    }

    public func references(in uri: ToolingDocumentURI, at position: ToolingPosition)
        async throws -> WorkspaceDemandResult<[ToolingLocation]> {
        try await demand { try await $0.references(in: uri, at: position) }
    }

    public func rename(in uri: ToolingDocumentURI, at position: ToolingPosition, to name: String)
        async throws -> WorkspaceDemandResult<ToolingWorkspaceEdit> {
        try await demand { try await $0.rename(in: uri, at: position, to: name) }
    }

    private func demand<Value: Sendable>(
        priority: WorkspacePriority = .interactive,
        query: @escaping @Sendable (LanguageToolingProject) async throws -> Value
    ) async throws -> WorkspaceDemandResult<Value> {
        guard let revision = submitted?.revision else { throw WorkspaceSchedulingError.noRevision }
        try Task.checkCancellation()
        sequence += 1
        let id = sequence
        if running {
            guard pending.count < maximumPendingRequests else {
                throw WorkspaceSchedulingError.queueFull
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.append(Waiter(id: id, revision: revision, priority: priority,
                                          continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        } else {
            running = true
        }
        defer { finish() }
        try validate(revision)
        try Task.checkCancellation()
        let task = Task(priority: priority == .interactive ? .userInitiated : .utility) {
            let analysis = try await self.materialize(revision)
            try self.validate(revision)
            try Task.checkCancellation()
            let value = try await query(self.project)
            return WorkspaceDemandResult(revision: revision, value: value, analysis: analysis)
        }
        cancelRunning = { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        try validate(revision)
        try Task.checkCancellation()
        return try result.get()
    }

    private func materialize(_ revision: UInt64) async throws -> ToolingProjectUpdateResult? {
        try validate(revision)
        guard let submitted else { throw WorkspaceSchedulingError.noRevision }
        if await project.revision == revision { return nil }
        try validate(revision)
        // An edit may refer to a skipped source generation. Reuse exact edits
        // only when their base is the project's committed source.
        let sources = await project.committedSources
        try validate(revision)
        let documents = submitted.documents.map { document in
            guard let change = document.change,
                  sources[document.uri] != change.before else { return document }
            return ToolingProjectDocumentUpdate(
                uri: document.uri, languageID: document.languageID, snapshot: document.snapshot)
        }
        return try await project.update(revision: revision, documents: documents)
    }

    private func validate(_ revision: UInt64) throws {
        if let current = submitted?.revision, current != revision {
            throw WorkspaceSchedulingError.superseded(requested: revision, current: current)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func finish() {
        cancelRunning = nil
        guard let next = pending.firstIndex(where: { $0.priority == .interactive })
                ?? pending.indices.first else {
            running = false
            return
        }
        pending.remove(at: next).continuation.resume()
    }
}
