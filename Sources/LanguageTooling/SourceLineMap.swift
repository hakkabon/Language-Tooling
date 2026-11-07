import Foundation
import IncrementalParsing

/// Maps absolute UTF-16 offsets to zero-based line/character positions.
public struct SourceLineMap: Sendable {
    private let codeUnits: [UInt16]
    private let starts: [Int]

    public init(_ source: String) {
        codeUnits = Array(source.utf16)
        var result = [0]
        var index = 0
        while index < codeUnits.count {
            if codeUnits[index] == 13 {
                index += 1
                if index < codeUnits.count, codeUnits[index] == 10 { index += 1 }
                result.append(index)
            } else if codeUnits[index] == 10 {
                index += 1
                result.append(index)
            } else {
                index += 1
            }
        }
        starts = result
    }

    public var utf16Length: Int { codeUnits.count }
    public var lineCount: Int { starts.count }

    public func offset(of position: ToolingPosition) -> Int? {
        guard position.line < starts.count else { return nil }
        let start = starts[position.line]
        let end = lineContentEnd(position.line)
        guard position.character <= end - start else { return nil }
        return start + position.character
    }

    public func position(of requestedOffset: Int) -> ToolingPosition {
        let offset = min(max(0, requestedOffset), codeUnits.count)
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 }
            else { high = middle }
        }
        let line = max(0, low - 1)
        return .init(line: line, character: offset - starts[line])
    }

    public func toolingRange(_ range: SourceRange) -> ToolingRange {
        .init(
            start: position(of: range.location),
            end: position(of: range.upperBound))
    }

    public func sourceRange(_ range: ToolingRange) -> SourceRange? {
        guard let start = offset(of: range.start),
              let end = offset(of: range.end), end >= start else { return nil }
        return .init(location: start, length: end - start)
    }

    public func applying(
        _ changes: [ToolingTextChange],
        to source: String
    ) throws -> String {
        var text = source
        for change in changes {
            if let range = change.range {
                let map = SourceLineMap(text)
                guard let sourceRange = map.sourceRange(range) else {
                    throw SourceLineMapError.invalidRange(range)
                }
                text = (text as NSString).replacingCharacters(
                    in: NSRange(
                        location: sourceRange.location,
                        length: sourceRange.length),
                    with: change.text)
            } else {
                text = change.text
            }
        }
        return text
    }

    private func lineContentEnd(_ line: Int) -> Int {
        guard line + 1 < starts.count else { return codeUnits.count }
        var end = starts[line + 1]
        if end > starts[line], codeUnits[end - 1] == 10 { end -= 1 }
        if end > starts[line], codeUnits[end - 1] == 13 { end -= 1 }
        return end
    }
}

public enum SourceLineMapError: Error, Hashable, Sendable {
    case invalidRange(ToolingRange)
}
