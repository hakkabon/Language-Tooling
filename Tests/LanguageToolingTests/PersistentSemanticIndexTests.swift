import Foundation
import LanguageTooling
import Testing

@Test func semanticCheckpointReusesOnlyMatchingDocuments() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("semantic-index.json")

    let library = ToolingDocumentURI("file:///library.test")
    let client = ToolingDocumentURI("file:///client.test")
    let unrelated = ToolingDocumentURI("file:///unrelated.test")
    func input(_ source: String, bindings: String = "initial") -> SemanticIndexInput {
        .init(languageID: "test", artifact: .init(id: "test", revision: 1, fingerprint: "grammar"),
              producerVersion: "1", bindingFingerprint: bindings, source: source)
    }
    let declaration = ProjectSymbolOccurrence(
        symbol: "library.answer", range: .init(location: 0, length: 6), role: .declaration)
    let reference = ProjectSymbolOccurrence(
        symbol: "library.answer", range: .init(location: 0, length: 6), role: .reference)
    let original = [library: input("answer"), client: input("answer"), unrelated: input("")]
    var index = PersistentSemanticIndex()
    try index.replace(.init(input: original[library]!, occurrences: [declaration]), at: library)
    try index.replace(.init(input: original[client]!, occurrences: [reference],
                            dependencies: [library]), at: client)
    try index.replace(.init(input: original[unrelated]!, occurrences: []), at: unrelated)
    try index.checkpoint(to: url)

    let warm = try PersistentSemanticIndex.restore(from: url, matching: original)
    #expect(warm.documents == index.documents)
    #expect(warm.occurrences(of: declaration.symbol) == [library: [declaration], client: [reference]])
    #expect(warm.affectedDocuments(by: [library]) == [client])

    let edited = [library: input("result"), client: input("answer", bindings: "changed"),
                  unrelated: original[unrelated]!]
    var cold = try PersistentSemanticIndex.restore(from: url, matching: edited)
    #expect(Set(cold.documents.keys) == [unrelated])
    #expect(cold.reconcile(with: edited) == [library, client])
    #expect(cold.occurrences(of: declaration.symbol).isEmpty)
    #expect(cold.reconcile(with: [:]).isEmpty)
    #expect(cold.documents.isEmpty)
    try index.replace(.init(input: edited[client]!, occurrences: []), at: client)
    #expect(index.affectedDocuments(by: [library]).isEmpty)
    #expect(index.occurrences(of: declaration.symbol) == [library: [declaration]])

    try Data(#"{"schemaVersion":99}"#.utf8).write(to: url)
    #expect(throws: SemanticIndexStorageError.unsupportedSchema(99)) {
        try PersistentSemanticIndex.restore(from: url, matching: original)
    }
}
