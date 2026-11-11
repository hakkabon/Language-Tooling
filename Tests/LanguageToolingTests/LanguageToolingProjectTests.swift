import IncrementalParsing
import LanguageTooling
import Testing

@Suite("Project-scale language tooling")
struct LanguageToolingProjectTests {
    @Test func projectCoordinatesDocumentsAndLanguageOwnedResolution() async throws {
        let resolver = TestProjectResolver()
        let project = LanguageToolingProject(
            providers: [ProjectTestProvider()], resolver: resolver)
        let library = ToolingDocumentURI("file:///library.test")
        let client = ToolingDocumentURI("file:///client.test")
        let librarySource = SourceSnapshot(text: "let answer", revision: .init(1))
        let clientSource = SourceSnapshot(text: "answer", revision: .init(1))

        let first = try await project.update(revision: 1, documents: [
            (library, "project-test", librarySource),
            (client, "project-test", clientSource),
        ])
        #expect(first.evidence.strategy == .full)
        #expect(first.rebuiltDocuments == [library, client])
        #expect(try await project.definition(
            in: client, at: .init(line: 0, character: 2))?.uri
            == library.rawValue)
        #expect(try await project.references(
            in: library, at: .init(line: 0, character: 5)).count == 2)
        let rename = try await project.rename(
            in: client, at: .init(line: 0, character: 2), to: "result")
        #expect(Set(rename.changes.keys) == [library, client])
        #expect(try await project.diagnostics()[client]?.count == 1)

        let clientChange = try SourceEdit(
            baseRevision: clientSource.revision,
            range: .init(location: 6, length: 0), replacement: " + 1")
            .applying(to: clientSource)
        let second = try await project.update(revision: 2, documents: [
            ToolingProjectDocumentUpdate(
                uri: library, languageID: "project-test",
                snapshot: librarySource),
            ToolingProjectDocumentUpdate(
                uri: client, languageID: "project-test",
                snapshot: clientChange.after, change: clientChange),
        ])
        #expect(second.evidence.strategy == .incremental)
        #expect(second.reusedDocuments == [library])
        #expect(second.rebuiltDocuments == [client])

        let third = try await project.update(revision: 3, documents: [
            (library, "project-test", librarySource),
        ])
        #expect(third.removedDocuments == [client])
        await #expect(throws: LanguageToolingProjectError.self) {
            try await project.update(
                revision: 3,
                documents: [ToolingProjectDocumentUpdate]())
        }
        #expect(await resolver.revisions == [1, 2, 3])
    }

    @Test func projectRejectsDuplicateDocumentsAndUnknownLanguages() async {
        let project = LanguageToolingProject(providers: [ProjectTestProvider()])
        let uri = ToolingDocumentURI("file:///same.test")
        let source = SourceSnapshot(text: "x", revision: .init(1))
        await #expect(throws: LanguageToolingProjectError.self) {
            try await project.update(revision: 1, documents: [
                (uri, "project-test", source), (uri, "project-test", source),
            ])
        }
        await #expect(throws: LanguageToolingProjectError.self) {
            try await project.update(revision: 1, documents: [
                (uri, "missing", source),
            ])
        }
    }
}

private struct ProjectTestProvider: LanguageToolingProvider {
    let descriptor = LanguageProviderDescriptor(
        id: "project-test", displayName: "Project Test",
        fileExtensions: ["test"], distribution: .hostDefined,
        capabilities: [.incrementalAnalysis, .diagnostics, .semantics])

    func makeToolingSession() -> any LanguageToolingSession {
        ProjectTestSession(uri: "language-document://project-test")
    }

    func makeToolingSession(documentURI: String) -> any LanguageToolingSession {
        ProjectTestSession(uri: documentURI)
    }
}

private actor ProjectTestSession: LanguageToolingSession {
    let uri: String
    init(uri: String) { self.uri = uri }

    func analyze(_ snapshot: SourceSnapshot, change: SourceChange?) async throws
        -> LanguageProviderAnalysis {
        .init(
            languageID: "project-test", revision: snapshot.revision,
            diagnostics: snapshot.text.hasPrefix("answer") ? [.init(
                id: "unresolved.answer", severity: .warning,
                message: "resolved by project", range: .init(location: 0, length: 6))] : [])
    }

    func definition(at position: ToolingPosition) async throws
        -> ToolingLocation? {
        .init(uri: uri, range: .init(start: position, end: position))
    }
}

private actor TestProjectResolver: LanguageToolingProjectResolver {
    private(set) var revisions: [UInt64] = []

    func update(_ snapshot: ToolingProjectSnapshot) async throws {
        revisions.append(snapshot.revision)
    }

    func definition(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> ToolingLocation? {
        .init(uri: "file:///library.test", range: .init(
            start: .init(line: 0, character: 4),
            end: .init(line: 0, character: 10)))
    }

    func references(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition
    ) async throws -> [ToolingLocation] {
        [
            .init(uri: "file:///library.test", range: .init(
                start: .init(line: 0, character: 4),
                end: .init(line: 0, character: 10))),
            .init(uri: "file:///client.test", range: .init(
                start: .init(line: 0, character: 0),
                end: .init(line: 0, character: 6))),
        ]
    }

    func rename(
        in snapshot: ToolingProjectSnapshot,
        document: ToolingDocumentURI,
        at position: ToolingPosition,
        to newName: String
    ) async throws -> ToolingWorkspaceEdit {
        .init(changes: [
            .init("file:///library.test"): [.init(
                range: .init(location: 4, length: 6), replacement: newName)],
            .init("file:///client.test"): [.init(
                range: .init(location: 0, length: 6), replacement: newName)],
        ])
    }
}
