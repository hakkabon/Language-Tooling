public enum SemanticTokenEncoder {
    /// Encodes the standard five-integer delta representation used by LSP.
    public static func encode(
        _ tokens: [ToolingSemanticToken],
        resultID: String,
        legend: [ToolingSemanticTokenType] = ToolingSemanticTokenType.allCases
    ) -> ToolingSemanticTokensResult {
        let sorted = tokens.sorted {
            ($0.range.start.line, $0.range.start.character)
                < ($1.range.start.line, $1.range.start.character)
        }
        var previousLine = 0, previousCharacter = 0
        var data: [Int] = []
        for token in sorted where token.range.start.line == token.range.end.line {
            guard let typeIndex = legend.firstIndex(of: token.type) else { continue }
            let deltaLine = token.range.start.line - previousLine
            let deltaCharacter = deltaLine == 0
                ? token.range.start.character - previousCharacter
                : token.range.start.character
            data += [
                deltaLine,
                deltaCharacter,
                token.range.end.character - token.range.start.character,
                typeIndex,
                token.isDeclaration ? 1 : 0,
            ]
            previousLine = token.range.start.line
            previousCharacter = token.range.start.character
        }
        return .init(resultID: resultID, data: data)
    }
}
