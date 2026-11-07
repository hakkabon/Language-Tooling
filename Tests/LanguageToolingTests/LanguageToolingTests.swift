import Foundation
import IncrementalParsing
import LanguageTooling
import LanguageToolingFormatting
import LanguageToolingTesting
import Testing

@Test func lineMapRoundTripsUTF16AndCRLF() throws {
    let text = "a😀\r\nbeta\n"
    let map = SourceLineMap(text)
    let position = ToolingPosition(line: 1, character: 2)
    let offset = try #require(map.offset(of: position))
    #expect(map.position(of: offset) == position)
    #expect(map.sourceRange(.init(start: .init(line: 0, character: 1),
                                  end: .init(line: 0, character: 3)))
        == SourceRange(location: 1, length: 2))
}

@Test func semanticIndexSupportsVisibilityNavigationAndRename() throws {
    let root = ToolingScopeID("root")
    let symbol = ToolingSymbol(
        id: .init("answer"), name: "answer", kind: .variable,
        declarationRange: .init(location: 0, length: 6), scopeID: root)
    let index = ToolingSemanticIndex(
        symbols: [symbol],
        references: [.init(
            symbolID: symbol.id, range: .init(location: 10, length: 6))],
        scopes: [.init(
            id: root, parentID: nil, range: .init(location: 0, length: 20),
            symbolIDs: [symbol.id])])

    #expect(index.symbol(at: 12) == symbol)
    #expect(index.visibleSymbols(at: 12) == [symbol])
    #expect(index.renameEdits(symbolID: symbol.id, to: "value").count == 2)
    try ToolingConformance.validate(index: index, utf16Length: 20)

    let encoded = try JSONEncoder().encode(index)
    let decoded = try JSONDecoder().decode(
        ToolingSemanticIndex.self, from: encoded)
    #expect(decoded == index)
    #expect(decoded.symbol(at: 12) == symbol)
}

@Test func semanticTokensUseDeterministicDeltaEncoding() {
    let tokens = [
        ToolingSemanticToken(
            range: .init(start: .init(line: 1, character: 3),
                         end: .init(line: 1, character: 6)),
            type: .variable),
        ToolingSemanticToken(
            range: .init(start: .init(line: 0, character: 0),
                         end: .init(line: 0, character: 2)),
            type: .keyword, isDeclaration: true),
    ]
    let result = SemanticTokenEncoder.encode(tokens, resultID: "revision:1")
    #expect(result.data == [0, 0, 2, 0, 1, 1, 3, 3, 5, 0])
}

@Test func formattingWriterOwnsOnlyWhitespaceMechanics() {
    var writer = FormattingWriter(indentationWidth: 2)
    writer.append("begin")
    writer.lineBreak()
    writer.indent()
    writer.append("call p;")
    writer.lineBreak()
    writer.dedent()
    writer.append("end.")
    #expect(writer.finish() == "begin\n  call p;\nend.\n")
}
