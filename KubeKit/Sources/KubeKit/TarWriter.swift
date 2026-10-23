import Foundation

/// Streams local files and folders as a POSIX tar archive (ustar, with pax headers for long
/// names and large files). Readable by GNU tar, BusyBox tar and bsdtar.
public struct TarWriter {
    public struct Entry: Sendable {
        public let url: URL
        /// Path inside the archive, `/`-separated, relative.
        public let archivePath: String
        public let isDirectory: Bool
        public let symlinkTarget: String?
        public let size: Int64
        public let mode: Int
        public let modified: Date
    }

    public static let skippedNames: Set<String> = [".DS_Store"]

    /// Collects every entry under the given roots; each root lands at the archive top level.
    public static func entries(for roots: [URL]) throws -> [Entry] {
        var result: [Entry] = []
        for root in roots {
            try collect(root, archivePath: root.lastPathComponent, into: &result)
        }
        return result
    }

    private static func collect(_ url: URL, archivePath: String, into result: inout [Entry]) throws {
        if skippedNames.contains(url.lastPathComponent) { return }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs[.type] as? FileAttributeType
        let mode = (attrs[.posixPermissions] as? Int ?? 0o644) & 0o7777
        let modified = attrs[.modificationDate] as? Date ?? Date()
        switch type {
        case .typeDirectory:
            result.append(Entry(url: url, archivePath: archivePath, isDirectory: true, symlinkTarget: nil, size: 0, mode: mode, modified: modified))
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try collect(child, archivePath: archivePath + "/" + child.lastPathComponent, into: &result)
            }
        case .typeSymbolicLink:
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            result.append(Entry(url: url, archivePath: archivePath, isDirectory: false, symlinkTarget: target, size: 0, mode: 0o777, modified: modified))
        case .typeRegular:
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            result.append(Entry(url: url, archivePath: archivePath, isDirectory: false, symlinkTarget: nil, size: size, mode: mode, modified: modified))
        default:
            break // sockets, devices, fifos can't be meaningfully copied
        }
    }

    /// Writes the archive. `progress` gets the running count of file content bytes written;
    /// throwing from it (e.g. on cancellation) aborts the archive.
    public static func write(
        _ entries: [Entry],
        to sink: (Data) throws -> Void,
        progress: (Int64) throws -> Void = { _ in }
    ) throws {
        var written: Int64 = 0
        for entry in entries {
            for block in headers(for: entry) { try sink(block) }
            guard !entry.isDirectory, entry.symlinkTarget == nil, entry.size > 0 else { continue }
            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { try? handle.close() }
            var remaining = entry.size
            while remaining > 0 {
                let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
                guard !chunk.isEmpty else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: entry.url.path, NSLocalizedDescriptionKey: "\(entry.url.lastPathComponent) changed while uploading"])
                }
                try sink(chunk)
                remaining -= Int64(chunk.count)
                written += Int64(chunk.count)
                try progress(written)
            }
            let padding = Int((512 - entry.size % 512) % 512)
            if padding > 0 { try sink(Data(count: padding)) }
        }
        try sink(Data(count: 1024))
    }

    static func headers(for entry: Entry) -> [Data] {
        let path = entry.isDirectory ? entry.archivePath + "/" : entry.archivePath
        var pax: [(String, String)] = []
        var name = path
        var prefix = ""
        if path.utf8.count > 100 {
            if let split = splitUstar(path) {
                (prefix, name) = split
            } else {
                pax.append(("path", path))
                name = String(decoding: path.utf8.suffix(100), as: UTF8.self)
            }
        }
        let link = entry.symlinkTarget ?? ""
        if link.utf8.count > 100 { pax.append(("linkpath", link)) }
        let maxOctalSize: Int64 = 0o77777777777
        if entry.size > maxOctalSize { pax.append(("size", String(entry.size))) }

        var blocks: [Data] = []
        if !pax.isEmpty {
            let body = pax.map(paxRecord).joined()
            let bodyData = Data(body.utf8)
            blocks.append(header(name: "PaxHeader/" + String(name.suffix(80)), prefix: "", mode: 0o644, size: Int64(bodyData.count), mtime: entry.modified, type: "x", link: ""))
            var padded = bodyData
            padded.append(Data(count: (512 - bodyData.count % 512) % 512))
            blocks.append(padded)
        }
        let type: Character = entry.isDirectory ? "5" : (entry.symlinkTarget != nil ? "2" : "0")
        let size = entry.isDirectory || entry.symlinkTarget != nil ? 0 : min(entry.size, maxOctalSize)
        blocks.append(header(name: name, prefix: prefix, mode: entry.mode, size: size, mtime: entry.modified, type: type, link: String(decoding: link.utf8.prefix(100), as: UTF8.self)))
        return blocks
    }

    /// ustar can hold up to 255 bytes by splitting at a `/` into prefix (≤155) and name (≤100).
    static func splitUstar(_ path: String) -> (String, String)? {
        let bytes = Array(path.utf8)
        guard bytes.count <= 256 else { return nil }
        for i in stride(from: min(155, bytes.count - 1), through: 1, by: -1) where bytes[i] == UInt8(ascii: "/") {
            let name = bytes[(i + 1)...]
            if name.count <= 100, !name.isEmpty {
                return (String(decoding: bytes[..<i], as: UTF8.self), String(decoding: name, as: UTF8.self))
            }
        }
        return nil
    }

    /// "<len> key=value\n", where len counts itself.
    static func paxRecord(_ kv: (String, String)) -> String {
        let payload = " \(kv.0)=\(kv.1)\n"
        let base = payload.utf8.count
        var length = base + String(base).count
        if String(length).count != String(base).count { length = base + String(length).count }
        return "\(length)\(payload)"
    }

    static func header(name: String, prefix: String, mode: Int, size: Int64, mtime: Date, type: Character, link: String) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ offset: Int, _ length: Int) {
            for (i, b) in s.utf8.prefix(length).enumerated() { h[offset + i] = b }
        }
        func octal(_ value: Int64, _ offset: Int, _ length: Int) {
            put(String(String(value, radix: 8).suffix(length - 1)).leftPad(to: length - 1), offset, length - 1)
        }
        put(name, 0, 100)
        octal(Int64(mode), 100, 8)
        octal(0, 108, 8) // uid: root, or the container user when tar can't chown
        octal(0, 116, 8) // gid
        octal(size, 124, 12)
        octal(Int64(max(0, mtime.timeIntervalSince1970)), 136, 12)
        put("        ", 148, 8)
        h[156] = type.asciiValue ?? UInt8(ascii: "0")
        put(link, 157, 100)
        put("ustar\0", 257, 6)
        put("00", 263, 2)
        put(prefix, 345, 155)
        let checksum = h.reduce(0) { $0 + Int($1) }
        put(String(String(checksum, radix: 8).leftPad(to: 6)) + "\0 ", 148, 8)
        return Data(h)
    }
}

private extension String {
    func leftPad(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
