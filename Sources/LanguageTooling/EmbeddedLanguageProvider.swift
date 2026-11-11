import Foundation
import IncrementalParsing

/// Discovers embedded content without coupling the language-provider contract
/// to a particular host syntax or application.
public protocol EmbeddedLanguageRegionResolver: Sendable {
    func regions(in snapshot: SourceSnapshot) -> [EmbeddedLanguageRegion]
}

/// Composes one host provider with independently owned providers for its
/// embedded regions. Child session state is retained by stable region ID.
public struct EmbeddedLanguageProvider: LanguageToolingProvider {
    public let descriptor: LanguageProviderDescriptor
    private let host: any LanguageToolingProvider
    private let embedded: [String: any LanguageToolingProvider]
    private let resolver: any EmbeddedLanguageRegionResolver

    public init(
        host: any LanguageToolingProvider,
        embedded providers: [any LanguageToolingProvider],
        resolver: any EmbeddedLanguageRegionResolver
    ) {
        precondition(Set(providers.map { $0.descriptor.id }).count == providers.count)
        self.host = host
        embedded = Dictionary(uniqueKeysWithValues:
            providers.map { ($0.descriptor.id, $0) })
        self.resolver = resolver
        var capabilities = host.descriptor.capabilities
        capabilities.insert(.embeddedLanguages)
        for capability in [
            LanguageProviderCapability.syntaxHighlighting,
            .incrementalAnalysis, .diagnostics, .recovery, .semantics,
        ] where providers.contains(where: {
            $0.descriptor.capabilities.contains(capability)
        }) {
            capabilities.insert(capability)
        }
        descriptor = .init(
            id: host.descriptor.id,
            displayName: host.descriptor.displayName,
            fileExtensions: host.descriptor.fileExtensions,
            distribution: host.descriptor.distribution,
            capabilities: capabilities)
    }

    public func makeToolingSession() -> any LanguageToolingSession {
        EmbeddedLanguageSession(
            host: host.makeToolingSession(),
            providers: embedded, resolver: resolver)
    }
}

private actor EmbeddedLanguageSession: LanguageToolingSession {
    private struct ChildState {
        let languageID: String
        let session: any LanguageToolingSession
        let snapshot: SourceSnapshot
    }

    private let host: any LanguageToolingSession
    private let providers: [String: any LanguageToolingProvider]
    private let resolver: any EmbeddedLanguageRegionResolver
    private var children: [String: ChildState] = [:]
    private var currentText: String?
    private var currentRevision: SourceRevision?
    private var currentAnalysis: LanguageProviderAnalysis?

    init(host: any LanguageToolingSession,
         providers: [String: any LanguageToolingProvider],
         resolver: any EmbeddedLanguageRegionResolver) {
        self.host = host
        self.providers = providers
        self.resolver = resolver
    }

    func analyze(_ snapshot: SourceSnapshot, change: SourceChange?) async throws
        -> LanguageProviderAnalysis {
        if let change, change.after != snapshot {
            throw LanguageProviderError.inconsistentChange
        }
        let hostAnalysis = try await host.analyze(snapshot, change: change)
        let previousRegionCount = children.count
        let regions = validRegions(resolver.regions(in: snapshot), snapshot: snapshot)
        let source = snapshot.text as NSString
        var nextChildren: [String: ChildState] = [:]
        var embeddedTokens: [LanguageProviderToken] = []
        var embeddedDiagnostics: [LanguageProviderDiagnostic] = []
        var embeddedRecoveryEdits: [LanguageProviderRecoveryEdit] = []
        var embeddedOperations: [LanguageProviderOperationEvidence] = []
        var reusedRegions = 0

        for region in regions {
            guard let provider = providers[region.languageID] else { continue }
            let text = source.substring(with: NSRange(
                location: region.range.location, length: region.range.length))
            let childSnapshot = SourceSnapshot(
                text: text, revision: snapshot.revision)
            let session: any LanguageToolingSession
            let analysis: LanguageProviderAnalysis
            if let previous = children[region.id],
               previous.languageID == region.languageID {
                session = previous.session
                let childChange = try transition(
                    from: previous.snapshot, to: childSnapshot)
                analysis = try await session.analyze(
                    childSnapshot, change: childChange)
                reusedRegions += 1
            } else {
                session = provider.makeToolingSession()
                analysis = try await session.analyze(childSnapshot, change: nil)
            }
            nextChildren[region.id] = .init(
                languageID: region.languageID,
                session: session, snapshot: childSnapshot)
            embeddedTokens += analysis.tokens.map {
                .init(
                    range: relocated($0.range, by: region.range.location),
                    classification: $0.classification,
                    modifiers: $0.modifiers.union([
                        "embedded.\(region.languageID)",
                    ]))
            }
            let namespace = "embedded.\(region.id)"
            embeddedDiagnostics += analysis.diagnostics.map {
                let moved = $0.relocated(
                    by: region.range.location, idPrefix: namespace)
                return .init(
                    id: moved.id, severity: moved.severity,
                    message: "[\(region.languageID)] \(moved.message)",
                    range: moved.range, expected: moved.expected)
            }
            embeddedRecoveryEdits += analysis.recoveryEdits.map {
                $0.relocated(
                    by: region.range.location,
                    diagnosticIDPrefix: namespace)
            }
            embeddedOperations += analysis.operations.map {
                .init(
                    operation: "embedded.\(region.id).\($0.operation)",
                    evidence: $0.evidence)
            }
        }
        children = nextChildren

        let regionRanges = regions.map(\.range)
        let hostTokens = hostAnalysis.tokens.filter { token in
            !regionRanges.contains { intersects(token.range, $0) }
        }
        let embeddingEvidence = IncrementalExecutionEvidence(
            strategy: reusedRegions > 0 ? .incremental : .full,
            measurements: [.init(
                dimension: .init(rawValue: "embeddedRegions"),
                reused: reusedRegions,
                rebuilt: regions.count - reusedRegions,
                removed: max(0, previousRegionCount - regions.count),
                strategy: "stable-region-sessions")])
        let result = LanguageProviderAnalysis(
            languageID: hostAnalysis.languageID,
            revision: snapshot.revision,
            artifact: hostAnalysis.artifact,
            tokens: (hostTokens + embeddedTokens).sorted {
                ($0.range.location, $0.range.length)
                    < ($1.range.location, $1.range.length)
            },
            diagnostics: hostAnalysis.diagnostics + embeddedDiagnostics,
            recoveryEdits: hostAnalysis.recoveryEdits + embeddedRecoveryEdits,
            embeddedRegions: regions,
            operations: hostAnalysis.operations + embeddedOperations + [
                .init(operation: "embedding", evidence: embeddingEvidence),
            ])
        currentText = snapshot.text
        currentRevision = snapshot.revision
        currentAnalysis = result
        return result
    }

    func semanticTokens() async throws -> ToolingSemanticTokensResult {
        guard let text = currentText, let revision = currentRevision,
              let analysis = currentAnalysis else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        let map = SourceLineMap(text)
        let source = text as NSString
        let tokens = analysis.tokens.flatMap { token -> [ToolingSemanticToken] in
            guard let type = semanticType(token.classification) else { return [] }
            var pieces: [ToolingSemanticToken] = []
            var lower = token.range.location
            while lower < token.range.upperBound {
                var upper = lower
                while upper < token.range.upperBound {
                    let unit = source.character(at: upper)
                    if unit == 10 || unit == 13 { break }
                    upper += 1
                }
                if upper > lower {
                    pieces.append(.init(
                        range: map.toolingRange(.init(lower, upper)),
                        type: type,
                        isDeclaration: token.modifiers.contains("declaration")))
                }
                guard upper < token.range.upperBound else { break }
                lower = upper + 1
                if source.character(at: upper) == 13,
                   lower < token.range.upperBound,
                   source.character(at: lower) == 10 {
                    lower += 1
                }
            }
            return pieces
        }
        return SemanticTokenEncoder.encode(
            tokens,
            resultID: "\(analysis.languageID):embedded:\(revision.rawValue)")
    }

    func format(_ snapshot: SourceSnapshot) async throws -> String {
        try await host.format(snapshot)
    }

    func previewHTML(_ snapshot: SourceSnapshot) async throws -> String? {
        try await host.previewHTML(snapshot)
    }

    private func validRegions(
        _ candidates: [EmbeddedLanguageRegion], snapshot: SourceSnapshot
    ) -> [EmbeddedLanguageRegion] {
        var upperBound = 0
        var ids = Set<String>()
        return candidates.sorted {
            ($0.range.location, $0.id) < ($1.range.location, $1.id)
        }.filter { region in
            guard providers[region.languageID] != nil,
                  ids.insert(region.id).inserted,
                  region.range.upperBound <= snapshot.utf16Count,
                  region.range.location >= upperBound else { return false }
            upperBound = region.range.upperBound
            return true
        }
    }

    private func transition(
        from before: SourceSnapshot, to after: SourceSnapshot
    ) throws -> SourceChange {
        let old = Array(before.text.utf16), new = Array(after.text.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix,
              suffix < new.count - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] {
            suffix += 1
        }
        let replacementUnits = new[prefix..<(new.count - suffix)]
        let replacement = String(decoding: replacementUnits, as: UTF16.self)
        return try SourceEditBatch(
            baseRevision: before.revision,
            resultRevision: after.revision,
            replacements: [.init(
                range: .init(prefix, old.count - suffix),
                replacement: replacement)])
            .applying(to: before)
    }

    private func relocated(_ range: SourceRange, by delta: Int) -> SourceRange {
        .init(location: range.location + delta, length: range.length)
    }

    private func intersects(_ lhs: SourceRange, _ rhs: SourceRange) -> Bool {
        lhs.location < rhs.upperBound && rhs.location < lhs.upperBound
    }

    private func semanticType(_ classification: String)
        -> ToolingSemanticTokenType? {
        switch classification {
        case "comment": .comment
        case "keyword": .keyword
        case "string", "code": .string
        case "number": .number
        case "constant": .constant
        case "identifier", "variable": .variable
        case "field", "attributeName": .field
        case "type", "tag", "heading": .type
        case "operator", "listMarker": .operatorToken
        default: nil
        }
    }
}
