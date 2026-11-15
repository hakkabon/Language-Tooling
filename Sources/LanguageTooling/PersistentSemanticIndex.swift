import CryptoKit
import Foundation
import IncrementalParsing

/// A language-owned project symbol key. Qualify keys with the language and
/// module wherever the language's binding rules require it.
public struct ProjectSymbolOccurrence: Hashable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case declaration, reference
    }

    public let symbol: String
    public let range: SourceRange
    public let role: Role

    public init(symbol: String, range: SourceRange, role: Role) {
        self.symbol = symbol
        self.range = range
        self.role = role
    }
}

public struct SemanticIndexInput: Hashable, Codable, Sendable {
    public let languageID: String
    public let artifact: IncrementalArtifactIdentity
    /// Version of the producer's symbol keys and semantic projection.
    public let producerVersion: String
    /// The producer must cover every external input that can change binding,
    /// including missing imports, configuration and dependency interfaces.
    public let bindingFingerprint: String
    public let sourceDigest: String
    public let sourceLength: Int

    public init(
        languageID: String, artifact: IncrementalArtifactIdentity,
        producerVersion: String, bindingFingerprint: String, source: String
    ) {
        self.languageID = languageID
        self.artifact = artifact
        self.producerVersion = producerVersion
        self.bindingFingerprint = bindingFingerprint
        sourceDigest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
        sourceLength = source.utf16.count
    }
}

public struct SemanticIndexDocument: Hashable, Codable, Sendable {
    public let input: SemanticIndexInput
    public let occurrences: [ProjectSymbolOccurrence]
    /// Direct dependencies selected by the language producer.
    public let dependencies: Set<ToolingDocumentURI>

    public init(
        input: SemanticIndexInput, occurrences: [ProjectSymbolOccurrence],
        dependencies: Set<ToolingDocumentURI> = []
    ) {
        self.input = input
        self.occurrences = occurrences
        self.dependencies = dependencies
    }

    private enum CodingKeys: String, CodingKey { case input, occurrences, dependencies }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(occurrences, forKey: .occurrences)
        try container.encode(dependencies.sorted(), forKey: .dependencies)
    }
}

public enum SemanticIndexStorageError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidDocument
    case duplicateDocument(String)
}

/// A host or resolver owns the file location and decides when to checkpoint.
/// Reverse indexes are rebuilt from validated records when opening a checkpoint.
public struct PersistentSemanticIndex: Sendable {
    private struct Record: Codable {
        let uri: String
        let document: SemanticIndexDocument
    }

    private struct Archive: Codable {
        let schemaVersion: Int
        let records: [Record]
    }

    public private(set) var documents: [ToolingDocumentURI: SemanticIndexDocument] = [:]
    private var bySymbol: [String: [ToolingDocumentURI: [ProjectSymbolOccurrence]]] = [:]
    private var dependents: [ToolingDocumentURI: Set<ToolingDocumentURI>] = [:]

    public init() {}

    public mutating func replace(_ document: SemanticIndexDocument, at uri: ToolingDocumentURI) throws {
        guard !uri.rawValue.isEmpty, !document.input.languageID.isEmpty,
              !document.input.producerVersion.isEmpty, !document.input.bindingFingerprint.isEmpty,
              document.input.sourceLength >= 0,
              document.dependencies.allSatisfy({ !$0.rawValue.isEmpty }),
              document.occurrences.allSatisfy({
                  !$0.symbol.isEmpty && $0.range.lowerBound >= 0
                      && $0.range.upperBound >= $0.range.lowerBound
                      && $0.range.upperBound <= document.input.sourceLength
              }) else { throw SemanticIndexStorageError.invalidDocument }
        remove(uri)
        documents[uri] = document
        for (symbol, occurrences) in Dictionary(grouping: document.occurrences, by: \.symbol) {
            bySymbol[symbol, default: [:]][uri] = occurrences
        }
        for dependency in document.dependencies {
            dependents[dependency, default: []].insert(uri)
        }
    }

    public mutating func remove(_ uri: ToolingDocumentURI) {
        guard let old = documents.removeValue(forKey: uri) else { return }
        for symbol in Set(old.occurrences.map(\.symbol)) {
            bySymbol[symbol]?.removeValue(forKey: uri)
            if bySymbol[symbol]?.isEmpty == true { bySymbol.removeValue(forKey: symbol) }
        }
        for dependency in old.dependencies {
            dependents[dependency]?.remove(uri)
            if dependents[dependency]?.isEmpty == true { dependents.removeValue(forKey: dependency) }
        }
    }

    public func occurrences(of symbol: String) -> [ToolingDocumentURI: [ProjectSymbolOccurrence]] {
        bySymbol[symbol] ?? [:]
    }

    /// Drop missing or stale records and return the documents needing analysis.
    @discardableResult
    public mutating func reconcile(
        with currentInputs: [ToolingDocumentURI: SemanticIndexInput]
    ) -> Set<ToolingDocumentURI> {
        let stale = documents.compactMap { uri, document in
            currentInputs[uri] == document.input ? nil : uri
        }
        for uri in stale { remove(uri) }
        return Set(currentInputs.keys).subtracting(documents.keys)
    }

    /// Transitive reverse dependency closure, excluding the supplied roots.
    public func affectedDocuments(by roots: Set<ToolingDocumentURI>) -> Set<ToolingDocumentURI> {
        var seen = roots
        var work = Array(roots)
        while let next = work.popLast() {
            for dependent in dependents[next, default: []] where seen.insert(dependent).inserted {
                work.append(dependent)
            }
        }
        return seen.subtracting(roots)
    }

    public func checkpoint(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = documents.keys.sorted().map {
            Record(uri: $0.rawValue, document: documents[$0]!)
        }
        try encoder.encode(Archive(schemaVersion: 1, records: records)).write(to: url, options: .atomic)
    }

    /// Reuse records only when current source, artifact and binding inputs match.
    /// Absent or mismatched records are cache misses for the caller to rebuild.
    public static func restore(
        from url: URL, matching currentInputs: [ToolingDocumentURI: SemanticIndexInput]
    ) throws -> Self {
        struct Header: Decodable { let schemaVersion: Int }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == 1 else {
            throw SemanticIndexStorageError.unsupportedSchema(header.schemaVersion)
        }
        let archive = try decoder.decode(Archive.self, from: data)
        var index = Self()
        var seen: Set<String> = []
        for record in archive.records {
            guard !record.uri.isEmpty else { throw SemanticIndexStorageError.invalidDocument }
            guard seen.insert(record.uri).inserted else {
                throw SemanticIndexStorageError.duplicateDocument(record.uri)
            }
            let uri = ToolingDocumentURI(record.uri)
            if currentInputs[uri] == record.document.input {
                try index.replace(record.document, at: uri)
            }
        }
        return index
    }
}
