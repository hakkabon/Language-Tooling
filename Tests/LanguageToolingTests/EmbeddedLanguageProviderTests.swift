import Foundation
import IncrementalParsing
@testable import LanguageTooling
import Testing

@Suite("Embedded language provider")
struct EmbeddedLanguageProviderTests {
    @Test func relocatesChildProductsAndRetainsRegionSession() async throws {
        let provider = EmbeddedLanguageProvider(
            host: MockProvider(id: "html", classification: "tag"),
            embedded: [MockProvider(id: "css", classification: "identifier")],
            resolver: MarkerResolver())
        let session = provider.makeToolingSession()
        #expect(provider.descriptor.capabilities.contains(.embeddedLanguages))
        let first = SourceSnapshot(
            text: "<style>bad</style>", revision: .init(1))
        let initial = try await session.analyze(first, change: nil)

        #expect(initial.embeddedRegions == [
            .init(id: "css.0", languageID: "css",
                  range: .init(location: 7, length: 3)),
        ])
        #expect(initial.tokens.contains {
            $0.range == .init(location: 7, length: 3)
                && $0.modifiers.contains("embedded.css")
        })
        #expect(initial.diagnostics.first?.range == .init(location: 7, length: 1))

        let change = try SourceEdit(
            baseRevision: first.revision,
            range: .init(location: 9, length: 1), replacement: "d!")
            .applying(to: first)
        let updated = try await session.analyze(change.after, change: change)
        #expect(updated.evidence(for: "embedding")?.strategy == .incremental)
        #expect(updated.evidence(for: "embedded.css.0.analysis")?.strategy
            == .incremental)
    }
}

private struct MarkerResolver: EmbeddedLanguageRegionResolver {
    func regions(in snapshot: SourceSnapshot) -> [EmbeddedLanguageRegion] {
        let source = snapshot.text as NSString
        let open = source.range(of: "<style>")
        let close = source.range(of: "</style>")
        guard open.location != NSNotFound, close.location != NSNotFound else {
            return []
        }
        let start = NSMaxRange(open)
        return [.init(
            id: "css.0", languageID: "css",
            range: .init(location: start, length: close.location - start))]
    }
}

private struct MockProvider: LanguageToolingProvider {
    let descriptor: LanguageProviderDescriptor
    let classification: String

    init(id: String, classification: String) {
        descriptor = .init(
            id: id, displayName: id, fileExtensions: [],
            distribution: .hostDefined,
            capabilities: [.syntaxHighlighting, .incrementalAnalysis, .diagnostics])
        self.classification = classification
    }

    func makeToolingSession() -> any LanguageToolingSession {
        MockSession(id: descriptor.id, classification: classification)
    }
}

private actor MockSession: LanguageToolingSession {
    let id: String
    let classification: String

    init(id: String, classification: String) {
        self.id = id
        self.classification = classification
    }

    func analyze(_ snapshot: SourceSnapshot, change: SourceChange?) async throws
        -> LanguageProviderAnalysis {
        let length = snapshot.utf16Count
        return .init(
            languageID: id, revision: snapshot.revision,
            tokens: length == 0 ? [] : [.init(
                range: .init(location: 0, length: length),
                classification: classification)],
            diagnostics: id == "css" && length > 0 ? [.init(
                severity: .error, message: "sample",
                range: .init(location: 0, length: 1))] : [],
            operations: [.init(operation: "analysis", evidence: .init(
                strategy: change == nil ? .full : .incremental,
                measurements: [.init(
                    dimension: .tokens, reused: change == nil ? 0 : 1,
                    rebuilt: change == nil ? 1 : 0)]))])
    }
}
