import Foundation

/// The store's CSV tables (one file per table, a header row, facts appended). The menu needs only the last row of
/// two small ones — `snapshot` and `host_sample` — so the file is read from its tail, never whole.
public enum CSV {
    /// RFC 4180 fields: commas, double quotes doubled inside quotes. No embedded newlines (sysobs writes none).
    public static func fields(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var it = line.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let ch = next() {
            if quoted {
                if ch == "\"" {
                    if let n = it.next() {
                        if n == "\"" { cur.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { cur.append(ch) }
            } else if ch == "\"" && cur.isEmpty {
                quoted = true
            } else if ch == "," {
                out.append(cur); cur = ""
            } else if ch == "\r" {
                continue
            } else {
                cur.append(ch)
            }
        }
        out.append(cur)
        return out
    }

    /// The last complete row of a table as header -> value. `header` is the file's first line; `tail` its last
    /// bytes, which begin mid-line when `tailBeginsMidLine` (the read started inside the file) and may end mid-line
    /// (a writer may be appending). A row whose field count disagrees with the header is skipped: the column-shifted
    /// row the README warns about, or a torn write.
    public static func lastRow(header headerLine: String, tail: String, tailBeginsMidLine: Bool) -> [String: String]? {
        let header = fields(headerLine.trimmingCharacters(in: .whitespacesAndNewlines))
        guard header.count > 1 else { return nil }
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if tailBeginsMidLine, !lines.isEmpty { lines.removeFirst() }
        if !tail.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        for line in lines.reversed() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == headerLine.trimmingCharacters(in: .whitespacesAndNewlines) { continue }
            let vals = fields(t)
            if vals.count == header.count {
                return Dictionary(uniqueKeysWithValues: zip(header, vals))
            }
        }
        return nil
    }

    /// Read a table's last complete row from disk, touching at most `tailBytes` of it. Read-only, no lock.
    public static func lastRow(of url: URL, tailBytes: Int = 16 * 1024) -> [String: String]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let headData = try? fh.read(upToCount: 4096), let head = String(data: headData, encoding: .utf8),
              let headerLine = head.split(separator: "\n", omittingEmptySubsequences: false).first,
              let size = try? fh.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        guard let tailData = try? fh.readToEnd() else { return nil }
        // a cut in the middle of a multibyte character makes the data undecodable; the fragment is dropped anyway
        var bytes = [UInt8](tailData)
        if start > 0, let nl = bytes.firstIndex(of: 10) { bytes.removeFirst(nl + 1) }
        return lastRow(header: String(headerLine), tail: String(decoding: bytes, as: UTF8.self), tailBeginsMidLine: false)
    }
}
