import Foundation

/// Splits a byte stream of concatenated JSON objects (as `kubectl get --watch -o json` emits) into
/// one `Data` per top-level object, regardless of how the stream is chunked or pretty-printed.
public struct JSONStreamSplitter: Sendable {
    private var buffer = [UInt8]()
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var start: Int?
    private var scanned = 0

    public init() {}

    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var objects: [Data] = []
        var i = scanned
        while i < buffer.count {
            let byte = buffer[i]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if depth == 0 { start = i }
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0, let s = start {
                        objects.append(Data(buffer[s...i]))
                        start = nil
                    }
                default:
                    break
                }
            }
            i += 1
        }
        if depth == 0 {
            buffer.removeAll(keepingCapacity: true)
            scanned = 0
        } else if let s = start, s > 0 {
            buffer.removeFirst(s)
            start = 0
            scanned = i - s
        } else {
            scanned = i
        }
        return objects
    }
}
